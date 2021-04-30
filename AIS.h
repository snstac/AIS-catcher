/*
Copyright(c) 2021 Jasper van den Eshof

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

#pragma once

#include "Stream.h"
#include "AIS.h"
#include "Signal.h"

namespace AIS
{
	enum class State { TRAINING, STARTFLAG, STOPFLAG, DATAFCS };

	class Decoder : public SimpleStreamInOut<BIT, NMEA>
	{
		char channel = '?';

		std::vector<BIT> DataFCS_Bits;
		std::vector<uint8_t> DataFCS;

		const int MaxBits = 512;

		BIT lastBit = 0;
		BIT prev = 0;

		int position = 0;
		int one_seq_count = 0;
		int SequenceNumber = 0;
		State state = State::TRAINING;

		void NextState(State s, int pos);
		char NMEAchar(int i);
		bool CRC16(int len);
		void setByteData(int len);
		char getFrame(int pos, int len);
		void SendNMEA(int len);
		void ProcessData(int len);

	public:

		Decoder();

		virtual void setChannel(char c) { channel = c; }
		void Receive(const BIT* data, int len);

		MessageHub<DecoderMessage> DecoderStateMessage;
	};
}
