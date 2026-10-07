//+------------------------------------------------------------------+
//|                                                   CandleEcho.mq5 |
//|   Trades the direction of the last completed candle. Holds for  |
//|   exactly N candles, then closes. Lot size follows an            |
//|   independent win/loss recovery sequence (direction and sizing   |
//|   are decoupled - see spec section 6).                           |
//+------------------------------------------------------------------+
#property copyright "CandleEcho"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
enum ENUM_DOJI_ACTION
  {
   DOJI_SKIP     = 0, // Skip the candle - no trade
   DOJI_BUY      = 1, // Treat as bullish
   DOJI_SELL     = 2, // Treat as bearish
   DOJI_PREVIOUS = 3  // Repeat previous direction
  };

input group "=== CANDLE SETTINGS ==="
input ENUM_DOJI_ACTION InpDojiAction          = DOJI_SKIP; // Doji behavior
input bool             InpReverseSignal       = false;     // true = trade opposite of the candle signal (mean-reversion test)

input group "=== POSITION SIZING ==="
input double           InpInitialLot          = 0.01;      // Base/reset lot size
input bool             InpEnableMartingale    = false;      // Off by default - research phase isolates signal from sizing
input double           InpLotMultiplier       = 2.0;        // Lot multiplier after a loss
input double           InpMaxLot              = 1.0;        // Hard lot ceiling
input int              InpMaxConsecutiveLosses= 6;          // Halt trading after N losses in a row

input group "=== TRADE MANAGEMENT ==="
input int              InpHoldCandles         = 1;          // Candles to hold each trade
input int              InpMaxOpenPositions    = 1;          // Safety cap (should stay 1)

input group "=== RISK PROTECTION ==="
input double           InpMaxSpreadPoints     = 20;         // Skip entry if spread exceeds this (0 = off)
input double           InpMaxDailyLossPercent = 5.0;        // Stop opening new trades after this daily loss (0 = off)
input int              InpMaxDailyTrades      = 0;          // Stop opening new trades after N trades/day (0 = unlimited)

input group "=== TRADING HOURS ==="
input bool             InpEnableSessionFilter = false;      // Restrict new entries to a session
input string           InpStartTime           = "08:00";    // Session start (HH:MM, server time)
input string           InpEndTime             = "18:00";    // Session end (HH:MM, server time)

input group "=== EA SETTINGS ==="
input long             InpMagicNumber         = 20261007;   // Unique magic number for this instance
input string           InpTradeComment        = "CandleEcho"; // Order comment

//+------------------------------------------------------------------+
//| State                                                             |
//+------------------------------------------------------------------+
CTrade  trade;

datetime g_lastBarTime      = 0;
ulong    g_positionTicket   = 0;
int      g_barsHeld         = 0;
double   g_currentLot       = 0.0;
int      g_consecutiveLosses= 0;
bool     g_tradingHalted    = false;
int      g_lastDirection    = 0;     // +1 buy, -1 sell, 0 none (for DOJI_PREVIOUS)
int      g_dailyTradeCount  = 0;
double   g_dailyStartBalance= 0.0;
datetime g_currentDay       = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_currentLot = NormalizeLot(InpInitialLot);

   if(InpHoldCandles < 1)
     {
      Print("CandleEcho: InpHoldCandles must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_currentDay = 0; // force CheckNewDay() to initialize on first tick
   g_lastBarTime = 0;

   Print("CandleEcho initialized on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period),
         " | base lot=", DoubleToString(g_currentLot,2),
         " | martingale=", (InpEnableMartingale ? "ON" : "OFF"),
         " | reverse=", (InpReverseSignal ? "ON" : "OFF"),
         " | magic=", InpMagicNumber);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Tick handler - all logic is driven off new-bar events             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == g_lastBarTime)
      return; // still inside the same candle - do nothing
   g_lastBarTime = barTime;

   CheckNewDay();
   ManageOpenPosition();
   TryOpenNewPosition();
  }

//+------------------------------------------------------------------+
//| Close the current position once it has been held long enough,    |
//| then update the recovery lot sizing from the result.              |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(g_positionTicket == 0)
      return;

   if(!PositionSelectByTicket(g_positionTicket))
     {
      // closed outside the EA's control (manual close, stopout, broker action)
      g_positionTicket = 0;
      g_barsHeld = 0;
      return;
     }

   g_barsHeld++;
   if(g_barsHeld < InpHoldCandles)
      return;

   bool   isWin = false;
   double netResult = 0.0;

   if(ClosePositionAndGetResult(g_positionTicket, isWin, netResult))
     {
      UpdateLotSizing(isWin);
      Print("CandleEcho: closed #", g_positionTicket,
            " net=", DoubleToString(netResult,2),
            " result=", (isWin ? "WIN" : "LOSS"),
            " nextLot=", DoubleToString(g_currentLot,2),
            " consecLosses=", g_consecutiveLosses);
     }

   g_positionTicket = 0;
   g_barsHeld = 0;
  }

//+------------------------------------------------------------------+
//| Decide direction from the candle that just completed and open    |
//| exactly one new position, subject to all safety filters.          |
//+------------------------------------------------------------------+
void TryOpenNewPosition()
  {
   if(g_positionTicket != 0)
      return;
   if(g_tradingHalted)
      return;
   if(InpEnableSessionFilter && !IsWithinSession())
      return;
   if(InpMaxDailyTrades > 0 && g_dailyTradeCount >= InpMaxDailyTrades)
      return;
   if(IsDailyLossLimitHit())
      return;
   if(CurrentOpenPositionsCount() >= InpMaxOpenPositions)
      return;

   int signalDirection = GetDirectionFromLastClosedCandle();
   if(signalDirection == 0)
      return; // doji skipped, or no decision

   int direction = InpReverseSignal ? -signalDirection : signalDirection;

   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints > 0 && spreadPoints > InpMaxSpreadPoints)
     {
      Print("CandleEcho: spread ", DoubleToString(spreadPoints,0),
            "pts exceeds max ", DoubleToString(InpMaxSpreadPoints,0), " - skipping this candle");
      return;
     }

   double lot = g_currentLot;
   bool   ok  = (direction == 1)
                ? trade.Buy(lot, _Symbol, 0, 0, 0, InpTradeComment)
                : trade.Sell(lot, _Symbol, 0, 0, 0, InpTradeComment);

   if(!ok)
     {
      Print("CandleEcho: order failed, err=", GetLastError());
      return;
     }

   ulong dealTicket = trade.ResultDeal();
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
      g_positionTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   g_barsHeld      = 0;
   g_lastDirection = signalDirection; // DOJI_PREVIOUS tracks the raw candle signal, not the (possibly reversed) trade direction
   g_dailyTradeCount++;

   Print("CandleEcho: opened ", (direction == 1 ? "BUY" : "SELL"),
         (InpReverseSignal ? " [REVERSED]" : ""),
         " lot=", DoubleToString(lot,2), " #", g_positionTicket);
  }

//+------------------------------------------------------------------+
//| +1 = bullish candle, -1 = bearish, 0 = no trade (doji/skip)        |
//+------------------------------------------------------------------+
int GetDirectionFromLastClosedCandle()
  {
   double openPrice  = iOpen(_Symbol, _Period, 1);
   double closePrice = iClose(_Symbol, _Period, 1);

   if(closePrice > openPrice)
      return 1;
   if(closePrice < openPrice)
      return -1;

   switch(InpDojiAction)
     {
      case DOJI_BUY:      return 1;
      case DOJI_SELL:      return -1;
      case DOJI_PREVIOUS: return g_lastDirection;
      default:             return 0; // DOJI_SKIP
     }
  }

//+------------------------------------------------------------------+
//| Close a position and return its net result (profit+swap+comm.)   |
//+------------------------------------------------------------------+
bool ClosePositionAndGetResult(ulong ticket, bool &isWin, double &netResult)
  {
   if(!trade.PositionClose(ticket))
     {
      Print("CandleEcho: failed to close #", ticket, " err=", GetLastError());
      return false;
     }

   netResult = 0.0;
   if(HistorySelectByPosition(ticket))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;
         netResult += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         netResult += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         netResult += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        }
     }

   isWin = (netResult > 0.0);
   return true;
  }

//+------------------------------------------------------------------+
//| Reset lot to base on a win; multiply (capped) on a loss.          |
//| Direction tracking is untouched here - sizing and direction are   |
//| deliberately independent (spec section 6).                        |
//+------------------------------------------------------------------+
void UpdateLotSizing(bool isWin)
  {
   if(isWin)
     {
      g_consecutiveLosses = 0;
      g_currentLot = NormalizeLot(InpInitialLot);
      return;
     }

   g_consecutiveLosses++;
   g_currentLot = InpEnableMartingale
                  ? NormalizeLot(g_currentLot * InpLotMultiplier)
                  : NormalizeLot(InpInitialLot);

   if(g_consecutiveLosses >= InpMaxConsecutiveLosses)
     {
      g_tradingHalted = true;
      Print("CandleEcho: max consecutive losses (", g_consecutiveLosses, ") reached - trading halted until next day");
     }
  }

//+------------------------------------------------------------------+
//| Clamp to [min,max] and round down to the symbol's volume step     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lot > InpMaxLot)
      lot = InpMaxLot;

   if(step > 0.0)
     {
      int digits = 0;
      double s = step;
      while(s < 0.999999 && digits < 8)
        {
         s *= 10.0;
         digits++;
        }
      lot = MathFloor(lot / step + 0.0000001) * step;
      lot = NormalizeDouble(lot, digits);
     }

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;

   return lot;
  }

//+------------------------------------------------------------------+
//| Count this EA's own open positions on this symbol                 |
//+------------------------------------------------------------------+
int CurrentOpenPositionsCount()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| "HH:MM" -> minutes since midnight                                 |
//+------------------------------------------------------------------+
int TimeStringToMinutes(const string t)
  {
   string parts[];
   int n = StringSplit(t, ':', parts);
   if(n < 2)
      return 0;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   return h * 60 + m;
  }

//+------------------------------------------------------------------+
//| Is current server time inside the configured session?             |
//| Supports overnight sessions (e.g. 22:00-06:00).                   |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   int startMin = TimeStringToMinutes(InpStartTime);
   int endMin   = TimeStringToMinutes(InpEndTime);

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int nowMin = now.hour * 60 + now.min;

   if(startMin == endMin)
      return true; // identical start/end = trade all day

   if(startMin < endMin)
      return (nowMin >= startMin && nowMin < endMin);

   return (nowMin >= startMin || nowMin < endMin);
  }

//+------------------------------------------------------------------+
//| Reset daily counters, balance baseline, the loss-streak halt, and |
//| the lot ladder whenever the server date rolls over. The lot must  |
//| reset in lockstep with the loss counter - otherwise an escalated  |
//| lot can survive into a day that thinks it has seen zero losses.   |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = 0;
   now.min  = 0;
   now.sec  = 0;
   datetime today = StructToTime(now);

   if(today == g_currentDay)
      return;

   g_currentDay        = today;
   g_dailyTradeCount    = 0;
   g_dailyStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_tradingHalted      = false;
   g_consecutiveLosses  = 0;
   g_currentLot         = NormalizeLot(InpInitialLot); // lot must restart with the streak, or an escalated lot survives into a "clean" day

   Print("CandleEcho: new trading day - daily counters reset, lot reset to ", DoubleToString(g_currentLot,2),
         ", balance baseline=", DoubleToString(g_dailyStartBalance,2));
  }

//+------------------------------------------------------------------+
//| Has today's floating/realized loss hit the configured cap?        |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
  {
   if(InpMaxDailyLossPercent <= 0.0 || g_dailyStartBalance <= 0.0)
      return false;

   double equityNow   = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (g_dailyStartBalance - equityNow) / g_dailyStartBalance * 100.0;

   if(lossPercent >= InpMaxDailyLossPercent)
     {
      Print("CandleEcho: daily loss limit hit (", DoubleToString(lossPercent,2), "%) - no new trades until next day");
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
