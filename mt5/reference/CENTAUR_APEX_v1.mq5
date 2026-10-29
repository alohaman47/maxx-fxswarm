//+------------------------------------------------------------------+
//| CENTAUR_APEX_v1.mq5                                              |
//| THE DEGEN BRANCH. Same DNA as CENTAUR, opposite temperament.     |
//|                                                                  |
//| What CENTAUR does : survive first, compound second.              |
//| What APEX does    : compound first, survive if convenient.       |
//|                                                                  |
//| Design of the aggression (4 multipliers stacked on each other):  |
//|   1. RATCHET COMPOUNDING - capital follows the high-water mark,  |
//|      never steps back down in a drawdown, and compounds 130% of  |
//|      profit (accelerated).                                       |
//|   2. PYRAMID - adds a new tranche every +0.5 ATR of favorable    |
//|      move, up to 4 adds. One basket, one shared trailing stop.   |
//|   3. HOT-HAND BOOST - each consecutive up-day multiplies size by |
//|      +15%, capped at 5 days (= x1.75 in a hot streak).           |
//|   4. NO DAILY EXIT - winners are held across days and trailed    |
//|      (chandelier from peak). CENTAUR flattened every 02:00.      |
//|                                                                  |
//| Armor that was REMOVED (all still present as switches, all OFF): |
//|   - PF throttle / hard brake (gone entirely)                     |
//|   - equity-HWM drawdown brake (gone entirely)                    |
//|   - ATR explosion guard (InpUseATRGuard=false by default)        |
//|   - token-touch day rule (InpDailyRule=false -> gate-off = flat) |
//| Armor that was KEPT, on purpose:                                 |
//|   - D1 EMA100 regime gate (this is the ONLY thing standing       |
//|     between the pyramid and a 2022-style bear market)            |
//|   - disaster stop + trailing stop (always present)               |
//|   - free-margin fitter (stops the broker rejecting orders and    |
//|     turning a strategy result into a plumbing result)            |
//+------------------------------------------------------------------+
#property copyright "Maxx / APEX branch"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_COMP_BASE
{
   COMP_EQUITY  = 0,   // Equity
   COMP_BALANCE = 1,   // Balance
   COMP_HWM     = 2    // High-Water Mark ratchet (degen default)
};

//--- engine
input double  InpTargetVol      = 0.025;  // daily vol target (CENTAUR: 0.010)
input double  InpLeverageCap    = 6.0;    // max exposure / capital (CENTAUR: 2.0)
input int     InpEmaPeriodD1    = 100;    // D1 regime EMA
input int     InpAtrPeriodD1    = 14;     // D1 ATR
input double  InpStopAtrMult    = 2.0;    // initial disaster stop (D1 ATR x)
input double  InpTrailAtrMult   = 2.5;    // chandelier trail from peak (D1 ATR x)
input int     InpRebalanceHour  = 2;      // server hour for the daily decision
input double  InpMaxSpreadPts   = 80;     // skip entry above this spread
//--- pyramid
input bool    InpPyramid        = true;   // add to winners
input int     InpMaxAdds        = 4;      // max add-on tranches
input double  InpAddStepATR     = 0.5;    // add every X ATR of favorable move
input double  InpAddSizeMult    = 1.0;    // add size = base x this^n (1.0 = flat)
//--- compounding
input ENUM_COMP_BASE InpCompBase = COMP_HWM;  // ratchet by default
input double  InpBaseCapital    = 0.0;    // start capital (0 = auto)
input double  InpCompoundRate   = 1.3;    // >1 = accelerated compounding
input double  InpMaxGrowthMult  = 100.0;  // ceiling vs start capital
input double  InpMinShrinkMult  = 0.10;   // floor vs start capital
//--- hot hand
input double  InpStreakBoost    = 0.15;   // +15% size per consecutive up-day
input int     InpStreakCap      = 5;      // max streak counted
//--- minimal survival plumbing
input double  InpMinMarginLevel = 200.0;  // skip NEW orders below this margin level %
input double  InpMarginUse      = 0.80;   // max fraction of free margin per order
//--- optional legacy armor (all off = degen mode)
input bool    InpDailyRule      = false;  // true = min-lot token trade on gate-off days
input bool    InpUseATRGuard    = false;  // true = skip entries on ATR explosion
input double  InpATRGuardMult   = 2.0;
input int     InpATRGuardBars   = 500;
//--- misc
input bool    InpLogSizing      = true;
input long    InpMagic          = 540003;
input bool    AllowLive         = false;  // must be true to run on REAL

//--- globals
CTrade   trade;
int      hEmaD1  = INVALID_HANDLE;
int      hAtrD1  = INVALID_HANDLE;
int      hAtrM15 = INVALID_HANDLE;
datetime g_lastBarTime  = 0;
datetime g_lastRebalDay = 0;
bool     g_tokenPos     = false;
datetime g_entryBarTime = 0;
string   g_hwmName;
double   g_baseCap      = 0.0;
//--- basket state
double   g_peak         = 0.0;   // highest bid since basket opened
double   g_lastAdd      = 0.0;   // price of the last tranche
int      g_adds         = 0;     // add-on count
double   g_basketSL     = 0.0;   // shared stop level
//--- streak state
int      g_streak       = 0;
double   g_lastEquity   = 0.0;

//+------------------------------------------------------------------+
string GVName(const string s)
{
   return "APEX_" + _Symbol + "_" + IntegerToString((int)InpMagic) + "_" + s;
}
//+------------------------------------------------------------------+
void PersistState()
{
   GlobalVariableSet(GVName("BASECAP"), g_baseCap);
   GlobalVariableSet(GVName("STREAK"),  (double)g_streak);
   GlobalVariableSet(GVName("LASTEQ"),  g_lastEquity);
   GlobalVariableSet(GVName("PEAK"),    g_peak);
   GlobalVariableSet(GVName("LASTADD"), g_lastAdd);
   GlobalVariableSet(GVName("ADDS"),    (double)g_adds);
   GlobalVariableSet(GVName("BSL"),     g_basketSL);
}
//+------------------------------------------------------------------+
void LoadState()
{
   if(GlobalVariableCheck(GVName("STREAK")))  g_streak     = (int)GlobalVariableGet(GVName("STREAK"));
   if(GlobalVariableCheck(GVName("LASTEQ")))  g_lastEquity = GlobalVariableGet(GVName("LASTEQ"));
   if(GlobalVariableCheck(GVName("PEAK")))    g_peak       = GlobalVariableGet(GVName("PEAK"));
   if(GlobalVariableCheck(GVName("LASTADD"))) g_lastAdd    = GlobalVariableGet(GVName("LASTADD"));
   if(GlobalVariableCheck(GVName("ADDS")))    g_adds       = (int)GlobalVariableGet(GVName("ADDS"));
   if(GlobalVariableCheck(GVName("BSL")))     g_basketSL   = GlobalVariableGet(GVName("BSL"));
}
//+------------------------------------------------------------------+
void InitBaseCapital()
{
   string bc = GVName("BASECAP");
   if(InpBaseCapital > 0.0)                                      g_baseCap = InpBaseCapital;
   else if(GlobalVariableCheck(bc) && GlobalVariableGet(bc) > 0) g_baseCap = GlobalVariableGet(bc);
   else                                                          g_baseCap = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_baseCap <= 0.0) g_baseCap = AccountInfoDouble(ACCOUNT_EQUITY);
   GlobalVariableSet(bc, g_baseCap);
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AllowLive && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("APEX: REAL account blocked. Set AllowLive=true to override.");
      return(INIT_FAILED);
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(60);

   hEmaD1  = iMA(_Symbol, PERIOD_D1, InpEmaPeriodD1, 0, MODE_EMA, PRICE_CLOSE);
   hAtrD1  = iATR(_Symbol, PERIOD_D1, InpAtrPeriodD1);
   hAtrM15 = iATR(_Symbol, PERIOD_M15, InpAtrPeriodD1);
   if(hEmaD1 == INVALID_HANDLE || hAtrD1 == INVALID_HANDLE || hAtrM15 == INVALID_HANDLE)
   {
      Print("APEX: indicator handle failed");
      return(INIT_FAILED);
   }
   g_hwmName = GVName("HWM");
   if(!GlobalVariableCheck(g_hwmName))
      GlobalVariableSet(g_hwmName, AccountInfoDouble(ACCOUNT_EQUITY));

   InitBaseCapital();
   LoadState();
   if(g_lastEquity <= 0.0) g_lastEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("APEX v1 online | DEGEN BRANCH | tvol=", DoubleToString(InpTargetVol, 3),
         " cap=", DoubleToString(InpLeverageCap, 1),
         " compBase=", EnumToString(InpCompBase),
         " rate=", DoubleToString(InpCompoundRate, 2),
         " pyramid=", (InpPyramid ? IntegerToString(InpMaxAdds) + " adds" : "off"),
         " streakBoost=", DoubleToString(InpStreakBoost, 2),
         " | startCap=", DoubleToString(g_baseCap, 2));
   Print("APEX: no PF throttle, no DD brake, no daily flat. Trailing stop and the ",
         "D1 EMA100 gate are the only brakes in this build.");
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
   int need = 22;
   double c[];
   if(CopyClose(_Symbol, PERIOD_D1, 1, need, c) < need) return(-1.0);
   ArraySetAsSeries(c, true);
   double sum = 0.0, sum2 = 0.0;
   for(int i = 0; i < 20; i++)
   {
      double r = c[i] / c[i + 1] - 1.0;
      sum += r; sum2 += r * r;
   }
   double mean = sum / 20.0;
   double var  = sum2 / 20.0 - mean * mean;
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
bool IsATRExplosion()
{
   if(!InpUseATRGuard) return(false);
   double nowBuf[];
   if(CopyBuffer(hAtrM15, 0, 1, 1, nowBuf) < 1) return(false);
   double atrNow = nowBuf[0];
   if(atrNow <= 0.0) return(false);
   double hist[];
   int copied = CopyBuffer(hAtrM15, 0, 1, InpATRGuardBars, hist);
   if(copied < InpATRGuardBars) return(false);
   double sum = 0.0;
   for(int i = 0; i < copied; i++) sum += hist[i];
   double avg = sum / (double)copied;
   if(avg <= 0.0) return(false);
   return(atrNow > InpATRGuardMult * avg);
}
//+------------------------------------------------------------------+
//| basket helpers (works on both hedging and netting accounts)      |
int PosCount()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return(n);
}
//+------------------------------------------------------------------+
double PosVolume()
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return(v);
}
//+------------------------------------------------------------------+
void CloseAllPos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      trade.PositionClose(tk);
   }
   g_peak = 0.0; g_lastAdd = 0.0; g_adds = 0; g_basketSL = 0.0;
   PersistState();
}
//+------------------------------------------------------------------+
void SetSLAll(const double sl)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double cur = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      if(cur <= 0.0 || sl > cur + _Point)
         trade.PositionModify(tk, sl, tp);
   }
}
//+------------------------------------------------------------------+
double CompoundCapital()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_baseCap <= 0.0) return(eq);

   double src = eq;
   if(InpCompBase == COMP_BALANCE) src = AccountInfoDouble(ACCOUNT_BALANCE);
   else if(InpCompBase == COMP_HWM)
   {
      double h = GlobalVariableGet(g_hwmName);
      src = MathMax(h, eq);
   }
   double cap = g_baseCap + (src - g_baseCap) * InpCompoundRate;
   double hi  = g_baseCap * InpMaxGrowthMult;
   double lo  = g_baseCap * InpMinShrinkMult;
   if(cap > hi) cap = hi;
   if(cap < lo) cap = lo;
   if(cap <= 0.0) cap = eq;
   return(cap);
}
//+------------------------------------------------------------------+
double StreakMult()
{
   int s = g_streak;
   if(s > InpStreakCap) s = InpStreakCap;
   if(s < 0) s = 0;
   return(1.0 + InpStreakBoost * (double)s);
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
//| fit the lot into free margin; returns 0 if it cannot be placed   |
double FitToMargin(double lot, const double price)
{
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * InpMarginUse;
   if(freeM <= 0.0) return(0.0);
   double need = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, price, need)) return(lot);
   if(need <= freeM) return(lot);
   double scaled = NormalizeLot(lot * (freeM / need));
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, scaled, price, need)) return(0.0);
   if(need > freeM) return(0.0);
   return(scaled);
}
//+------------------------------------------------------------------+
bool MarginOK()
{
   double lvl = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(lvl <= 0.0) return(true);            // no open margin yet
   return(lvl >= InpMinMarginLevel);
}
//+------------------------------------------------------------------+
//| open one tranche                                                 |
bool OpenTranche(const double lotWanted, const double atr, const bool token)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return(false);
   double lot = FitToMargin(NormalizeLot(lotWanted), ask);
   if(lot <= 0.0)
   {
      Print("APEX: order skipped, not enough free margin");
      return(false);
   }
   double sl = NormalizeDouble(ask - InpStopAtrMult * atr, _Digits);
   if(g_basketSL > 0.0 && g_basketSL > sl) sl = g_basketSL;

   if(!trade.Buy(lot, _Symbol, 0.0, sl, 0.0, token ? "APEX token" : "APEX"))
   {
      Print("APEX: buy failed err=", GetLastError());
      return(false);
   }
   if(g_basketSL <= 0.0) g_basketSL = sl;
   g_lastAdd = ask;
   if(g_peak <= 0.0) g_peak = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_entryBarTime = iTime(_Symbol, PERIOD_M15, 0);
   PersistState();
   return(true);
}
//+------------------------------------------------------------------+
//| daily decision at InpRebalanceHour                               |
void DailyDecision()
{
   double ema, atr;
   if(!GetD1(ema, atr)) return;
   double rv = RealizedVolD1();
   if(rv <= 0.0) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double hwm = GlobalVariableGet(g_hwmName);
   if(equity > hwm) { hwm = equity; GlobalVariableSet(g_hwmName, hwm); }

   // hot-hand streak: up-day vs down-day on equity
   if(g_lastEquity > 0.0)
   {
      if(equity > g_lastEquity) g_streak++;
      else                      g_streak = 0;
   }
   g_lastEquity = equity;

   double closeD1 = iClose(_Symbol, PERIOD_D1, 1);
   bool gateOn = (closeD1 > ema);

   if(!gateOn)
   {
      if(PosCount() > 0) CloseAllPos();          // regime off = flat, no debate
      if(InpDailyRule)                           // optional token touch
      {
         if(OpenTranche(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), atr, true))
            g_tokenPos = true;
      }
      g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
      return;
   }

   if(IsATRExplosion())
   {
      g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
      return;
   }

   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPts) return;       // retry next M15 bar

   if(PosCount() > 0)                            // already riding: pyramid handles it
   {
      g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
      return;
   }
   if(!MarginOK()) { g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0); return; }

   double lev = InpTargetVol / rv;
   if(lev > InpLeverageCap) lev = InpLeverageCap;

   double capital  = CompoundCapital() * StreakMult();
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(ask <= 0.0 || contract <= 0.0) return;
   double lotRaw = capital * lev / ask / contract;

   if(InpLogSizing)
      Print("APEX [size] cap=", DoubleToString(capital, 2),
            " eq=", DoubleToString(equity, 2),
            " streak=", g_streak, " x", DoubleToString(StreakMult(), 2),
            " lev=", DoubleToString(lev, 2),
            " lotRaw=", DoubleToString(lotRaw, 4));

   g_basketSL = 0.0; g_peak = 0.0; g_adds = 0;
   if(OpenTranche(lotRaw, atr, false))
      g_tokenPos = false;
   g_lastRebalDay = iTime(_Symbol, PERIOD_D1, 0);
}
//+------------------------------------------------------------------+
//| pyramid + trailing, evaluated every M15 bar                      |
void ManageBasket()
{
   if(PosCount() == 0) { g_peak = 0.0; g_adds = 0; g_basketSL = 0.0; return; }

   double ema, atr;
   if(!GetD1(ema, atr)) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   if(bid > g_peak) g_peak = bid;

   // chandelier trail from the running peak
   double trail = NormalizeDouble(g_peak - InpTrailAtrMult * atr, _Digits);
   if(trail > g_basketSL)
   {
      g_basketSL = trail;
      SetSLAll(g_basketSL);
   }

   // pyramid: add on every InpAddStepATR of favorable move
   if(!InpPyramid || g_adds >= InpMaxAdds) { PersistState(); return; }
   if(g_lastAdd <= 0.0) { PersistState(); return; }
   if(bid < g_lastAdd + InpAddStepATR * atr) { PersistState(); return; }
   if(!MarginOK()) { PersistState(); return; }

   double closeD1 = iClose(_Symbol, PERIOD_D1, 1);
   if(closeD1 <= ema) { PersistState(); return; }   // never pyramid against the gate

   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPts) { PersistState(); return; }

   double rv = RealizedVolD1();
   if(rv <= 0.0) { PersistState(); return; }
   double lev = InpTargetVol / rv;
   if(lev > InpLeverageCap) lev = InpLeverageCap;

   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(ask <= 0.0 || contract <= 0.0) { PersistState(); return; }

   double base   = CompoundCapital() * StreakMult() * lev / ask / contract;
   double lotAdd = base * MathPow(InpAddSizeMult, (double)(g_adds + 1));

   if(OpenTranche(lotAdd, atr, false))
   {
      g_adds++;
      if(InpLogSizing)
         Print("APEX [pyramid] add #", g_adds, " lot=", DoubleToString(lotAdd, 2),
               " basketVol=", DoubleToString(PosVolume(), 2),
               " trailSL=", DoubleToString(g_basketSL, _Digits));
   }
   PersistState();
}
//+------------------------------------------------------------------+
void OnTick()
{
   if(!NewM15Bar()) return;

   // token position (only if InpDailyRule) lives exactly one M15 bar
   if(g_tokenPos && PosCount() > 0 && iTime(_Symbol, PERIOD_M15, 0) > g_entryBarTime)
   {
      CloseAllPos();
      g_tokenPos = false;
   }

   if(!g_tokenPos) ManageBasket();

   MqlDateTime st;
   TimeToStruct(iTime(_Symbol, PERIOD_M15, 0), st);
   datetime today = iTime(_Symbol, PERIOD_D1, 0);

   if(g_lastRebalDay != today && st.hour >= InpRebalanceHour)
      DailyDecision();
}
//+------------------------------------------------------------------+
