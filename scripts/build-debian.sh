#!/bin/bash
#
# build-debian.sh - Build AIS-catcher Debian package
#
# Usage: ./build-debian.sh [-o output_dir] [-j jobs] [--skip-deps]
#
# Environment: RUN_NUMBER - Build number for versioning (default: 0)
#

set -euo pipefail

# Detect project root (look for CMakeLists.txt)
find_project_root() {
    local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/CMakeLists.txt" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    # Fallback to current directory
    pwd
}

readonly PROJECT_ROOT="$(find_project_root)"
readonly PACKAGE_NAME="ais-catcher"
readonly LIB_INSTALL_DIR="/usr/lib/${PACKAGE_NAME}"

# Directories
readonly BUILD_DIR="${PROJECT_ROOT}/build"

# Source repositories
readonly RTLSDR_REPO="https://gitea.osmocom.org/sdr/rtl-sdr.git"
readonly HYDRASDR_REPO="https://github.com/hydrasdr/hydrasdr-host.git"
readonly NMEA2000_REPO="https://github.com/ttlappalainen/NMEA2000.git"

# Build dependencies (for apt-get)
readonly BUILD_DEPS=(
    build-essential
    cmake
    debhelper
    git
    pkg-config
    libairspy-dev
    libairspyhf-dev
    libhackrf-dev
    libzmq3-dev
    libssl-dev
    zlib1g-dev
    libsqlite3-dev
    libusb-1.0-0-dev
    libpq-dev
    # SoapySDR is the only way to reach an SDR that has no dedicated backend
    # here -- LimeSDR, PlutoSDR, bladeRF, SDRplay, or anything behind
    # SoapyRemote. Without it AIS-catcher can only talk to RTL/Airspy/HackRF,
    # which is why the DragonEgg (LimeSDR Mini v2) box could not receive AIS at
    # all: `-l` listed only the GPS, never the Lime.
    #
    # This dep alone is NOT sufficient -- CMakeLists.txt has
    # `option(SOAPYSDR "Include Soapy SDR support" OFF)`, which is not
    # auto-detect, so build_aiscatcher() must also pass -DSOAPYSDR=ON.
    libsoapysdr-dev
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
error() { log "ERROR: $*"; exit 1; }

install_build_deps() {
    log "Installing build dependencies..."
    export DEBIAN_FRONTEND=noninteractive

    if [[ $EUID -eq 0 ]]; then
        apt-get update -qq
        apt-get install -y -qq "${BUILD_DEPS[@]}"
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${BUILD_DEPS[@]}"
    fi
}

build_rtlsdr() {
    log "Building rtl-sdr library..."
    local src_dir="${BUILD_DIR}/rtl-sdr"
    local install_dir="${BUILD_DIR}/local"

    git clone --depth 1 "${RTLSDR_REPO}" "${src_dir}"

    cmake -S "${src_dir}" -B "${src_dir}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DINSTALL_UDEV_RULES=ON \
        -DDETACH_KERNEL_DRIVER=ON

    cmake --build "${src_dir}/build" -j "${JOBS}"
    cmake --install "${src_dir}/build"
}

build_hydrasdr() {
    log "Building libhydrasdr library..."
    local src_dir="${BUILD_DIR}/hydrasdr-host"
    local install_dir="${BUILD_DIR}/local"

    git clone --depth 1 "${HYDRASDR_REPO}" "${src_dir}"

    # Use pkg-config to find libusb (more reliable than manual search)
    local libusb_libdir
    libusb_libdir=$(pkg-config --variable=libdir libusb-1.0 2>/dev/null || true)

    local cmake_args="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${install_dir}"

    # If pkg-config found libusb, help CMake find it
    if [[ -n "${libusb_libdir}" ]]; then
        cmake_args="${cmake_args} -DLIBUSB_LIBRARIES=${libusb_libdir}/libusb-1.0.so"
        cmake_args="${cmake_args} -DLIBUSB_INCLUDE_DIRS=$(pkg-config --variable=includedir libusb-1.0)/libusb-1.0"
    fi

    cmake -S "${src_dir}/libhydrasdr" -B "${src_dir}/libhydrasdr/build" ${cmake_args}

    cmake --build "${src_dir}/libhydrasdr/build" -j "${JOBS}"
    cmake --install "${src_dir}/libhydrasdr/build"
}

build_nmea2000() {
    log "Building NMEA2000 library..."
    local src_dir="${BUILD_DIR}/NMEA2000"

    git clone --depth 1 "${NMEA2000_REPO}" "${src_dir}"

    pushd "${src_dir}/src" > /dev/null
    g++ -O3 -c \
        N2kMsg.cpp \
        N2kStream.cpp \
        N2kMessages.cpp \
        N2kTimer.cpp \
        NMEA2000.cpp \
        N2kGroupFunctionDefaultHandlers.cpp \
        N2kGroupFunction.cpp \
        -I.
    ar rcs libnmea2000.a ./*.o
    popd > /dev/null
}

build_aiscatcher() {
    log "Building AIS-catcher..."
    local run_num="${RUN_NUMBER:-0}"
    local install_dir="${BUILD_DIR}/local"

    # Allow git to work with mounted directories in Docker
    git config --global --add safe.directory '*' 2>/dev/null || true

    # Set up environment to find locally built libraries
    export PKG_CONFIG_PATH="${install_dir}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CMAKE_PREFIX_PATH="${install_dir}:${CMAKE_PREFIX_PATH:-}"
    export LD_LIBRARY_PATH="${install_dir}/lib:${LD_LIBRARY_PATH:-}"

    cmake -S "${PROJECT_ROOT}" -B "${BUILD_DIR}/aiscatcher" \
        -DCMAKE_BUILD_TYPE=Release \
        -DSOAPYSDR=ON \
        -DNMEA2000_PATH="${BUILD_DIR}" \
        -DRPATH_LIBRARY_DIR="${LIB_INSTALL_DIR}" \
        -DRUN_NUMBER="${run_num}"

    cmake --build "${BUILD_DIR}/aiscatcher" -j "${JOBS}"

    # Fail loudly if SoapySDR did not actually get compiled in.
    #
    # cmake's SOAPYSDR block is `pkg_check_modules(...)` guarded: if the dev
    # package is missing it prints a status line and carries on building a
    # binary that silently cannot see half our SDRs. That is exactly how the
    # shipped 0.68-snstac1 debs ended up with zero SoapySDR linkage while CI
    # stayed green -- nothing ever asserted the feature was present.
    if ! ldd "${BUILD_DIR}/aiscatcher/AIS-catcher" 2>/dev/null | grep -qi soapysdr; then
        error "SoapySDR support was requested (-DSOAPYSDR=ON) but the binary does not link libSoapySDR. Is libsoapysdr-dev installed?"
    fi
    log "SoapySDR support confirmed linked into AIS-catcher"
}

get_version() {
    local binary="${BUILD_DIR}/aiscatcher/AIS-catcher"

    if [[ ! -f "${binary}" ]]; then
        error "AIS-catcher binary not found at ${binary}"
    fi

    if [[ ! -x "${binary}" ]]; then
        error "AIS-catcher binary is not executable: ${binary}"
    fi

    # Read STDOUT only, and pick the version line out of it by shape.
    #
    # This used to be `$(... 2>&1)` followed by a substring test rejecting any
    # output containing "error". That worked only while the binary was quiet.
    # Once SoapySDR is enabled the loader pulls in every installed Soapy module
    # -- UHD, audio, remote -- and they announce themselves on stderr before
    # main() runs:
    #
    #   [INFO] [UHD] linux; GNU C++ version 13.2.0; Boost_108300; UHD_4.6.0.0
    #   [ERROR] avahi_service_browser_new() failed: Bad state
    #   ALSA lib conf.c:5208:(_snd_config_evaluate) ... returned error: ...
    #
    # so the capture contained "error", the guard fired, and the build died
    # with "Failed to extract version" -- while the real version sat on the
    # last line of the very output being rejected. The version was never the
    # problem; the noise was.
    local raw version
    raw=$("${binary}" -h build 2>/dev/null) || error "AIS-catcher failed to run"

    # The version is printed alone on its own line, e.g. "v0.68-0-g2829d7e".
    # Anchoring to start-of-line keeps "UHD_4.6.0.0" and friends out even if a
    # future module decides to log to stdout.
    version=$(printf '%s\n' "${raw}" | tr -d '\r' \
        | grep -E '^[[:space:]]*v?[0-9]+\.[0-9]+' | tail -n 1 | tr -d '[:space:]')

    if [[ -z "${version}" ]]; then
        error "Failed to extract version from AIS-catcher binary. Raw output: ${raw}"
    fi

    log "Extracted version: ${version}"

    # Convert to Debian version format: remove 'v' prefix, replace first '-' with '~'
    echo "${version}" | sed 's/^v//' | sed 's/-/~/'
}

generate_changelog() {
    local version="$1"
    log "Generating debian/changelog for version ${version}..."
    cat > "${PROJECT_ROOT}/debian/changelog" << EOF
ais-catcher (${version}) unstable; urgency=low

  * Automated build.

 -- jvde-github <jvde-github@gmail.com>  $(date -R)
EOF
}

build_package() {
    local version arch output_file

    version=$(get_version)
    arch="$(dpkg --print-architecture)"

    log "Package version: ${version}"
    log "Architecture: ${arch}"

    generate_changelog "${version}"

    log "Building package with debhelper..."
    cd "${PROJECT_ROOT}"
    # -d: skip build-dep check — deps are installed by install_build_deps() above
    dpkg-buildpackage -b --no-sign -d

    # dpkg-buildpackage writes the .deb one level above the source tree
    local deb_file="${PROJECT_ROOT}/../ais-catcher_${version}_${arch}.deb"
    output_file="${OUTPUT_DIR}/ais-catcher.deb"
    mv "${deb_file}" "${output_file}"

    # Verify package
    log "Verifying package..."
    dpkg-deb --info "${output_file}"

    log "Package created: ${output_file}"
}

main() {
    local JOBS SKIP_DEPS

    JOBS=$(nproc)
    OUTPUT_DIR="${PROJECT_ROOT}"
    SKIP_DEPS=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--jobs)     JOBS="$2"; shift 2 ;;
            -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
            --skip-deps)   SKIP_DEPS=true; shift ;;
            *) error "Unknown option: $1" ;;
        esac
    done

    export JOBS OUTPUT_DIR

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}/local" "${OUTPUT_DIR}"

    [[ "${SKIP_DEPS}" == false ]] && install_build_deps

    build_rtlsdr
    build_hydrasdr
    build_nmea2000
    build_aiscatcher
    build_package

    log "Build completed successfully!"
}

main "$@"
