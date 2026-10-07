//+------------------------------------------------------------------+
//|                                CandleEcho_ResearchExport.mq5     |
//|   One-shot export of candle-shape stats + next-candle outcome,   |
//|   over the current chart's symbol/period, to a CSV for offline   |
//|   analysis (e.g. does body/range% predict next-candle behavior). |
//|   Run it directly on a chart - it is not an Expert Advisor.      |
//+------------------------------------------------------------------+
#property copyright "CandleEcho"
#property version   "1.00"
#property strict
#property script_show_inputs

input int    InpBarsToExport = 0;  // Rows to export, oldest-first (0 = all available history)
input string InpFileSuffix   = ""; // Optional suffix, e.g. "H1_2026" -> ..._H1_2026.csv

//+------------------------------------------------------------------+
//| Script entry point                                                |
//+------------------------------------------------------------------+
void OnStart()
  {
   int totalBars = Bars(_Symbol, _Period);
   int maxPairs  = totalBars - 2; // need a signal candle (shift i+1) and a next candle (shift i), both fully closed

   if(maxPairs < 1)
     {
      Print("CandleEcho research export: not enough history loaded (", totalBars, " bars) - load more history and retry");
      return;
     }

   int rows = (InpBarsToExport <= 0) ? maxPairs : (int)MathMin(InpBarsToExport, maxPairs);

   string filename = "CandleEcho_Research_" + _Symbol + "_" + EnumToString((ENUM_TIMEFRAMES)_Period);
   if(InpFileSuffix != "")
      filename += "_" + InpFileSuffix;
   filename += ".csv";

   int handle = FileOpen(filename, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("CandleEcho research export: failed to open ", filename, " err=", GetLastError());
      return;
     }

   FileWriteString(handle,
      "Time,Symbol,Timeframe,PrevOpen,PrevHigh,PrevLow,PrevClose,CandleDirection,CandleBody,CandleRange,BodyRangePercent,NextCandleDirection,NextCandleReturn,Spread\r\n");

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Walk oldest -> newest. i is the "next" candle's shift; i+1 is the signal candle's shift.
   for(int i = rows; i >= 1; i--)
     {
      int signalShift = i + 1;
      int nextShift    = i;

      double   pOpen  = iOpen(_Symbol, _Period, signalShift);
      double   pHigh  = iHigh(_Symbol, _Period, signalShift);
      double   pLow   = iLow(_Symbol, _Period, signalShift);
      double   pClose = iClose(_Symbol, _Period, signalShift);
      datetime pTime  = iTime(_Symbol, _Period, signalShift);

      double nOpen   = iOpen(_Symbol, _Period, nextShift);
      double nClose  = iClose(_Symbol, _Period, nextShift);
      int    nSpread = iSpread(_Symbol, _Period, nextShift); // spread at the candle where the trade would actually be entered

      int candleDirection;
      if(pClose > pOpen)
         candleDirection = 1;
      else if(pClose < pOpen)
         candleDirection = -1;
      else
         candleDirection = 0;

      double body         = MathAbs(pClose - pOpen);
      double range         = pHigh - pLow;
      double bodyRangePct = (range > 0.0) ? (body / range * 100.0) : 0.0;

      int nextDirection;
      if(nClose > nOpen)
         nextDirection = 1;
      else if(nClose < nOpen)
         nextDirection = -1;
      else
         nextDirection = 0;

      double nextReturn = nClose - nOpen;

      string line = StringFormat("%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%.2f,%d,%s,%d",
         TimeToString(pTime, TIME_DATE | TIME_SECONDS),
         _Symbol,
         EnumToString((ENUM_TIMEFRAMES)_Period),
         DoubleToString(pOpen, digits),
         DoubleToString(pHigh, digits),
         DoubleToString(pLow, digits),
         DoubleToString(pClose, digits),
         candleDirection,
         DoubleToString(body, digits),
         DoubleToString(range, digits),
         bodyRangePct,
         nextDirection,
         DoubleToString(nextReturn, digits),
         nSpread);

      FileWriteString(handle, line + "\r\n");
     }

   FileClose(handle);
   Print("CandleEcho research export complete: ", rows, " rows written to MQL5/Files/", filename);
  }
//+------------------------------------------------------------------+
