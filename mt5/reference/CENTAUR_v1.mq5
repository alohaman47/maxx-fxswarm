//+------------------------------------------------------------------+
//| CENTAUR_v1.mq5                                                   |
//| HYBRID: Claude ATLAS v6 engine  x  Kimi V4.1 defense layers      |
//| Commissioned by the tournament referee (Maxx) as entry #3        |
//|                                                                  |
//| BODY (Claude ATLAS v6, unchanged):                               |
//|   - Daily 02:00 rebalance, LONG only, 1 trade/day                |
//|   - Size = Equity * min(TargetVol/RealizedVol20, Cap)            |
//|   - D1 EMA100 gate scales SIZE (off-day = token-touch:           |
//|     min lot, exit next M15 bar)                                  |
//|   - Equity-HWM brake 8% -> half size                             |
//|   - Disaster stop 1.3 * ATR14(D1), no TP                         |
//| ARMOR (Kimi V4.1, adapted to daily-long rhythm):                 |
//|   1. ATR Explosion Guard: M15 ATR14 > 2.0 x its 500-bar mean     |
//|      at rebalance -> force token-touch day (no overnight hold)   |
//|   2. R-based rolling PF throttle: PF(R) of last 60 closed        |
//|      trades < 1.00 -> size x0.5 until PF(R) > 1.10 (hysteresis)  |
//|      (Kimi used x0.25; x0.5 chosen per the min-lot quantization  |
//|      finding at 10k deposit)                                     |
//|   3. Hard Brake: PF(R) < 0.60 -> token-touch mode for 7 days     |
//|      (Kimi halted trading; token keeps the 1-trade/day rule)     |
//|   4. Leverage cap: already present in the body (vcap)            |
//| State (throttle/hard-brake/open-risk) persists via              |
//| GlobalVariables, Kimi-style.                                     |
//+------------------------------------------------------------------+
#property copyright "Team Claude x Team Kimi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- ATLAS body inputs (frozen)
input double  InpTargetVol     = 0.010;   // daily vol target (fraction)
input double  InpLeverageCap   = 2.0;     // max exposure / equity
input double  InpGateFraction  = 0.05;    // size fraction on regime-off days
input int     InpEmaPeriodD1   = 100;     // D1 trend EMA period
input int     InpAtrPeriodD1   = 14;      // D1 ATR period
input double  InpStopAtrMult   = 1.3;     // disaster stop = D1 ATR * mult
input int     InpRebalanceHour = 2;       // server hour to rebalance
input double  InpBrakeDD       = 0.08;    // equity-HWM DD brake trigger
input double  InpBrakeCut      = 0.5;     // brake size multiplier
input int     InpVolLookback   = 20;      // realized vol lookback (D1)
input double  InpMaxSpreadPts  = 60;      // wait if spread above (max 4 bars)
//--- Kimi armor inputs
input double  InpATRGuardMult  = 2.0;     // [armor1] M15 ATR explosion multiple
input int     InpATRGuardBars  = 500;     // [armor1] bars for ATR mean
input int     InpPFWindow      = 60;      // [armor2] closed trades in PF window
input double  InpPFTrigger     = 1.00;    // [armor2] PF(R) below -> derisk
input double  InpPFRecover     = 1.10;    // [armor2] PF(R) above -> recover
input double  InpThrottleCut   = 0.5;     // [armor2] derisk size multiplier
input double  InpPFHardBrake   = 0.60;    // [armor3] PF(R) below -> hard brake
input int     InpHardBrakeDays = 7;       // [armor3] token-mode days
//--- identity
input long    InpMagic         = 540001;  // magic number
input bool    AllowLive        = false;   // must be true to run on REAL

//--- globals
CTrade   trade;
int      hEmaD1  = INVALID_HANDLE;
int      hAtrD1  = INVALID_HANDLE;
int      hAtrM15 = INVALID_HANDLE;
datetime g_lastBarTime   = 0;
datetime g_lastRebalDay  = 0;
int      g_spreadWaits   = 0;
bool     g_tokenPos      = false;
datetime g_entryBarTime  = 0;
string   g_hwmName;
//--- armor state
double   g_rWin[];                 // rolling R window
bool     g_derisked      = false;
datetime g_hbUntil       = 0;
double   g_openRiskMoney = 0.0;

//+------------------------------------------------------------------+
string GVName(const string suffix)
{
   return "CENTAUR_" + _Symbol + "_" + IntegerToString((int)InpMagic) + "_" + suffix;
}
//+------------------------------------------------------------------+
void PersistState()
{
   GlobalVariableSet(GVName("DERISK"),   g_derisked ? 1.0 : 0.0);
   GlobalVariableSet(GVName("HBUNTIL"),  (double)g_hbUntil);
   GlobalVariableSet(GVName("OPENRISK"), g_openRiskMoney);
}
//+------------------------------------------------------------------+
void LoadState()
{
   if(GlobalVariableCheck(GVName("DERISK")))
      g_derisked = (GlobalVariableGet(GVName("DERISK")) != 0.0);
   if(GlobalVariableCheck(GVName("HBUNTIL")))
      g_hbUntil = (datetime)GlobalVariableGet(GVName("HBUNTIL"));
   if(GlobalVariableCheck(GVName("OPENRISK")))
      g_openRiskMoney = GlobalVariableGet(GVName("OPENRISK"));
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AllowLive && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("CENTAUR: REAL account blocked. Set AllowLive=true to override.");
      return(INIT_FAILED);
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);

   hEmaD1  = iMA(_Symbol, PERIOD_D1, InpEmaPeriodD1, 0, MODE_EMA, PRICE_CLOSE);
   hAtrD1  = iATR(_Symbol, PERIOD_D1, InpAtrPeriodD1);
   hAtrM15 = iATR(_Symbol, PERIOD_M15, InpAtrPeriodD1);
   if(hEmaD1 == INVALID_HANDLE || hAtrD1 == INVALID_HANDLE || hAtrM15 == INVALID_HANDLE)
   {
      Print("CENTAUR: indicator handle failed");
      return(INIT_FAILED);
   }
   g_hwmName = GVName("HWM");
   if(!GlobalVariableCheck(g_hwmName))
      GlobalVariableSet(g_hwmName, AccountInfoDouble(ACCOUNT_EQUITY));
   ArrayResize(g_rWin, 0);   // R window starts empty after restart (Kimi-style)
   LoadState();
   Print("CENTAUR v1 online | body=ATLAS_v6 | armor=Kimi{ATRguard,PF-throttle,hard-brake}",
         " | derisked=", (g_derisked ? "true" : "false"),
         " | hbUntil=", (g_hbUntil > 0 ? TimeToString(g_hbUntil) : "-"));
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { PersistState(); }
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
   ArraySetAsSeries(c, true);
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
//| [armor1] Kimi ATR Explosion Guard on M15                         |
bool IsATRExplosion()
{
   double nowBuf[];
   if(CopyBuffer(hAtrM15, 0, 1, 1, nowBuf) < 1) return(false);
   double atrNow = nowBuf[0];
   if(atrNow <= 0.0) return(false);
   double hist[];
   int copied = CopyBuffer(hAtrM15, 0, 1, InpATRGuardBars, hist);
   if(copied < InpATRGuardBars) return(false);   // not enough history yet
   double sum = 0.0;
   for(int i = 0; i < copied; i++) sum += hist[i];
   double avg = sum / (double)copied;
   if(avg <= 0.0) return(false);
   if(atrNow > InpATRGuardMult * avg)
   {
      Print("CENTAUR [ATRguard] explosion: ATR=", DoubleToString(atrNow, _Digits),
            " > ", DoubleToString(InpATRGuardMult, 1), " x mean ",
            DoubleToString(avg, _Digits), " -> token-touch day");
      return(true);
   }
   return(false);
}
//+------------------------------------------------------------------+
//| [armor2] rolling PF from R window                                |
double RollingPF()
{
   int n = ArraySize(g_rWin);
   if(n == 0) return(0.0);
   double gp = 0.0, gl = 0.0;
   for(int i = 0; i < n; i++)
   {
      if(g_rWin[i] > 0.0) gp += g_rWin[i];
      else                gl += -g_rWin[i];
   }
   if(gl <= 0.0) return(gp > 0.0 ? DBL_MAX : 1.0);
   return(gp / gl);
}
//+------------------------------------------------------------------+
void AddClosedR(const double r)
{
   int sz = ArraySize(g_rWin);
   if(sz < InpPFWindow)
   {
      ArrayResize(g_rWin, sz + 1);
      g_rWin[sz] = r;
   }
   else
   {
      for(int i = 0; i < sz - 1; i++) g_rWin[i] = g_rWin[i + 1];
      g_rWin[sz - 1] = r;
   }
}
//+------------------------------------------------------------------+
void EvaluateArmor()
{
   if(ArraySize(g_rWin) < InpPFWindow) return;   // wait for a full window
   double pf = RollingPF();
   if(pf < InpPFHardBrake)
   {
      g_hbUntil = TimeCurrent() + (datetime)InpHardBrakeDays * 86400;
      Print("CENTAUR [HardBrake] PF(R)=", DoubleToString(pf, 2),
            " < ", DoubleToString(InpPFHardBrake, 2),
            " -> token-touch mode until ", TimeToString(g_hbUntil));
   }
   if(!g_derisked && pf < InpPFTrigger)
   {
      g_derisked = true;
      Print("CENTAUR [Throttle] DE-RISK ON: PF(R)=", DoubleToString(pf, 2));
   }
   else if(g_derisked && pf > InpPFRecover)
   {
      g_derisked = false;
      Print("CENTAUR [Throttle] DE-RISK OFF: PF(R)=", DoubleToString(pf, 2));
   }
   PersistState();
}
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(g_openRiskMoney > 0.0)
   {
      AddClosedR(pnl / g_openRiskMoney);
      g_openRiskMoney = 0.0;
      EvaluateArmor();
   }
   PersistState();
}
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) stepLot = 0.01;
   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return(lot);
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
void Rebalance()
{
   double ema, atr;
   if(!GetD1(ema, atr)) return;
   double rv = RealizedVolD1();
   if(rv <= 0.0) return;

   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPts && g_spreadWaits < 4)
   {
      g_spreadWaits++;
      return;
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
   bool token  = !gateOn;
   if(IsATRExplosion())            token = true;   // armor 1
   if(TimeCurrent() < g_hbUntil)   token = true;   // armor 3

   double frac = token ? InpGateFraction : 1.0;
   if(hwm > 0 && (1.0 - equity / hwm) > InpBrakeDD) frac *= InpBrakeCut;
   if(g_derisked) frac *= InpThrottleCut;           // armor 2

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;

   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double oz  = equity * lev * frac / ask;
   double lot = NormalizeLot(oz / contract);

   double sl = NormalizeDouble(ask - InpStopAtrMult * atr, _Digits);

   if(!trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "CENTAUR daily"))
      Print("CENTAUR: buy failed err=", GetLastError());
   else
   {
      g_tokenPos      = token;
      g_entryBarTime  = iTime(_Symbol, PERIOD_M15, 0);
      g_openRiskMoney = lot * contract * (ask - sl);   // for R at close
      PersistState();
   }
   g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
}
//+------------------------------------------------------------------+
void OnTick()
{
   if(!NewM15Bar()) return;

   // token-touch exit: token position held one M15 bar only
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

   if(!doneToday && st.hour >= InpRebalanceHour)
      Rebalance();
}
//+------------------------------------------------------------------+
