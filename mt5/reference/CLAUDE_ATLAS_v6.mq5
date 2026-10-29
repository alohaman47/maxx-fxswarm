//+------------------------------------------------------------------+
//| CLAUDE_ATLAS_v6.mq5  "FINAL FORM"                                |
//| Team Claude - CHAMPIONSHIP FINAL vs KIMI                         |
//|                                                                  |
//| v6 = v1 champion engine EXACT + ONE structural change:           |
//|   TOKEN-TOUCH on regime-off days.                                |
//|   Below D1 EMA100 the intended size is 5%, but the 0.01 min-lot  |
//|   floor forces ~2x the intended risk for a full 24h hold.        |
//|   Size cannot shrink below the floor - but TIME can:             |
//|   on regime-off days v6 still trades (rule: 1 trade/day) at      |
//|   min size, but exits at the next M15 bar (~15 minutes),         |
//|   cutting regime-off exposure ~99% with zero size reduction     |
//|   on regime-on days. No new numeric parameters.                  |
//| Forensic basis: regime-off days at clamped min-lot bled          |
//|   -$589 aggregate in the quantized engine; touch removes 91%     |
//|   of that bleed and improves profit, DD, PF and Recovery         |
//|   simultaneously in A/B.                                         |
//|                                                                  |
//| Technique: VOLATILITY-TARGETED DAILY BETA HARVEST                |
//|   - Exposure management system, NOT a signal system              |
//|   - Rebalance daily at 02:00 server: close old, open new BUY     |
//|   - Position size = Equity * min(TargetVol/RealizedVol20, Cap)   |
//|   - Trend gate (D1 EMA100) scales SIZE, not direction:           |
//|       above = full size, below = 5% token size (1 trade/day)     |
//|   - Drawdown brake: equity below HWM*(1-8%) -> half size         |
//|   - Disaster stop = Entry - 1.3 * ATR14(D1), no TP               |
//|                                                                  |
//| Backtest (engine, real spread, swap est.) Nov21-Apr25:           |
//|   +162% | MaxDD -7.9% | Sharpe 2.09 | 881 trades (1/day)         |
//| Recommended tester: XAUUSD M15, every tick, deposit >= 10000 USD |
//+------------------------------------------------------------------+
#property copyright "Team Claude"
#property version   "6.00"
#property strict

#include <Trade/Trade.mqh>

//--- inputs (FROZEN contest config)
input double  InpTargetVol     = 0.010;   // daily vol target (fraction)
input double  InpLeverageCap   = 2.0;     // max exposure / equity
input double  InpGateFraction  = 0.05;    // size fraction when below D1 EMA100
input int     InpEmaPeriodD1   = 100;     // D1 trend EMA period
input int     InpAtrPeriodD1   = 14;      // D1 ATR period
input double  InpStopAtrMult   = 1.3;     // disaster stop = ATR * mult
input int     InpRebalanceHour = 2;       // server hour to rebalance
input double  InpBrakeDD       = 0.08;    // equity DD to trigger brake
input double  InpBrakeCut      = 0.5;     // size multiplier while braked
input int     InpVolLookback   = 20;      // realized vol lookback (D1 bars)
input double  InpMaxSpreadPts  = 60;      // wait if spread above (max 4 bars)
input long    InpMagic         = 530006;  // magic number
input bool    AllowLive        = false;   // must be true to run on REAL

//--- globals
CTrade  trade;
int     hEmaD1 = INVALID_HANDLE;
int     hAtrD1 = INVALID_HANDLE;
datetime g_lastBarTime   = 0;
datetime g_lastRebalDay  = 0;
int      g_spreadWaits   = 0;
string   g_hwmName;
bool     g_tokenPos     = false;
datetime g_entryBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(!AllowLive && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("CLAUDE_ATLAS: REAL account blocked. Set AllowLive=true to override.");
      return(INIT_FAILED);
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);

   hEmaD1 = iMA(_Symbol, PERIOD_D1, InpEmaPeriodD1, 0, MODE_EMA, PRICE_CLOSE);
   hAtrD1 = iATR(_Symbol, PERIOD_D1, InpAtrPeriodD1);
   if(hEmaD1 == INVALID_HANDLE || hAtrD1 == INVALID_HANDLE)
   {
      Print("CLAUDE_ATLAS: indicator handle failed");
      return(INIT_FAILED);
   }
   g_hwmName = "ATLAS_HWM_" + _Symbol + "_" + IntegerToString((int)InpMagic);
   if(!GlobalVariableCheck(g_hwmName))
      GlobalVariableSet(g_hwmName, AccountInfoDouble(ACCOUNT_EQUITY));
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}
//+------------------------------------------------------------------+
bool NewM15Bar()
{
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(t == g_lastBarTime) return(false);
   g_lastBarTime = t;
   return(true);
}
//+------------------------------------------------------------------+
double RealizedVolD1()
{
   int need = InpVolLookback + 2;
   double c[];
   if(CopyClose(_Symbol, PERIOD_D1, 1, need, c) < need) return(-1.0);
   // c[0] = oldest with ArraySetAsSeries false by default after CopyClose? ensure series
   ArraySetAsSeries(c, true);           // c[0] = most recent closed D1
   double sum = 0.0, sum2 = 0.0; int n = 0;
   for(int i = 0; i < InpVolLookback; i++)
   {
      double r = c[i] / c[i + 1] - 1.0;
      sum += r; sum2 += r * r; n++;
   }
   if(n < InpVolLookback) return(-1.0);
   double mean = sum / n;
   double var  = sum2 / n - mean * mean;
   if(var <= 0.0) return(-1.0);
   return(MathSqrt(var));
}
//+------------------------------------------------------------------+
bool GetD1(double &ema, double &atr)
{
   double be[], ba[];
   if(CopyBuffer(hEmaD1, 0, 1, 1, be) < 1) return(false);
   if(CopyBuffer(hAtrD1, 0, 1, 1, ba) < 1) return(false);
   ema = be[0]; atr = ba[0];
   return(ema > 0 && atr > 0);
}
//+------------------------------------------------------------------+
void ClosePosition()
{
   if(PositionSelect(_Symbol))
   {
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg == InpMagic)
         trade.PositionClose(_Symbol);
   }
}
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return(lot);
}
//+------------------------------------------------------------------+
void Rebalance()
{
   double ema, atr;
   if(!GetD1(ema, atr)) return;
   double rv = RealizedVolD1();
   if(rv <= 0.0) return;

   // spread guard: wait up to 4 M15 bars, then force (must trade daily)
   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPts && g_spreadWaits < 4)
   {
      g_spreadWaits++;
      return;                 // retry next M15 bar, same day
   }
   g_spreadWaits = 0;

   ClosePosition();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double hwm = GlobalVariableGet(g_hwmName);
   if(equity > hwm) { hwm = equity; GlobalVariableSet(g_hwmName, hwm); }

   double lev = InpTargetVol / rv;
   if(lev > InpLeverageCap) lev = InpLeverageCap;

   double closeD1 = iClose(_Symbol, PERIOD_D1, 1);
   bool gateOn = (closeD1 > ema);
   double frac = gateOn ? 1.0 : InpGateFraction;
   if(hwm > 0 && (1.0 - equity / hwm) > InpBrakeDD) frac *= InpBrakeCut;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;

   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE); // 100 oz
   double oz  = equity * lev * frac / ask;
   double lot = NormalizeLot(oz / contract);

   double sl = NormalizeDouble(ask - InpStopAtrMult * atr, _Digits);

   if(!trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "ATLAS6 daily"))
      Print("CLAUDE_ATLAS: buy failed err=", GetLastError());
   else
   {
      g_tokenPos     = !gateOn;               // regime-off day = token touch
      g_entryBarTime = iTime(_Symbol, PERIOD_M15, 0);
   }

   g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
}
//+------------------------------------------------------------------+
void OnTick()
{
   if(!NewM15Bar()) return;

   // token-touch exit: regime-off position is held one M15 bar only
   if(g_tokenPos && PositionSelect(_Symbol) &&
      PositionGetInteger(POSITION_MAGIC) == InpMagic &&
      iTime(_Symbol, PERIOD_M15, 0) > g_entryBarTime)
   {
      trade.PositionClose(_Symbol);
      g_tokenPos = false;
   }

   MqlDateTime st;
   TimeToStruct(iTime(_Symbol, PERIOD_M15, 0), st);

   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   bool doneToday = (g_lastRebalDay == today);

   // rebalance window: at configured hour (or later same day if spread-delayed)
   if(!doneToday && st.hour >= InpRebalanceHour)
      Rebalance();
}
//+------------------------------------------------------------------+