//+------------------------------------------------------------------+
//| MaxxFxSwarm_v2.mq5                                               |
//| MAXX FX SWARM - EA hands for the AI server (25 FX pairs, M15)    |
//| EA posts closed bars -> server asks AI -> EA polls commands.     |
//| All money rules live HERE, the AI only picks pair + direction.   |
//+------------------------------------------------------------------+
#property copyright "MAXX"
#property version   "2.10"
#property description "MAXX FX SWARM v2 - FX AI module + GOLD module (ATLAS v6 / CENTAUR)"

#include <Trade\Trade.mqh>

//--- connection
input string InpURL            = "PASTE-RAILWAY-URL";              // Server base URL, e.g. https + your-app.up.railway.app (no trailing slash)
input string InpKey            = "change-me-long-key";              // Must equal MAXX_KEY on Railway
input bool   InpDryRun         = true;                              // true = log only, no real orders
input long   InpMagic          = 600200;                            // Magic number
//--- universe
input string InpSymbols        = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,EURGBP,EURJPY,GBPJPY,AUDJPY,EURAUD,EURCHF,GBPCHF,CADJPY,CHFJPY,NZDJPY,AUDCAD,AUDNZD,GBPAUD,GBPCAD,EURCAD,EURNZD,GBPNZD,AUDCHF";
input string InpSuffix         = "";                                // Broker symbol suffix, e.g. ".a"
input ENUM_TIMEFRAMES InpTF    = PERIOD_M15;                        // Signal timeframe
input int    InpBarsToSend     = 300;                               // Closed bars sent per pair
input int    InpATRPeriod      = 14;                                // ATR period
//--- sizing
input double InpRiskUSD        = 5.0;                               // Risk per trade in USD at the 1 ATR stop
input double InpMaxLot         = 0.10;                              // Hard lot cap per trade
input double InpMinLotRiskMult = 1.5;                               // Allow min lot if its risk <= RiskUSD x this
//--- portfolio guards
input int    InpMaxPositions   = 6;                                 // Max open positions (all pairs)
input int    InpMaxPerCurrency = 2;                                 // Max net same-direction exposure per currency
input int    InpMaxTradesDay   = 20;                                // Max new trades per NY day
input double InpDayLossUSD     = 100.0;                             // Day loss stop (closed + floating)
input double InpDayProfitUSD   = 200.0;                             // Day profit stop (closed + floating)
input double InpMaxSpreadATR   = 0.15;                              // Skip if spread > this x ATR
//--- exits (ATR multiples)
input double InpSL_ATR         = 1.0;                               // Stop loss
input double InpTP_ATR         = 3.0;                               // Take profit
input double InpBE_ATR         = 1.0;                               // Move SL to entry at
input double InpTrailStart_ATR = 1.5;                               // Start trailing at
input double InpTrailDist_ATR  = 1.0;                               // Trail distance
input int    InpMaxHoldBars    = 32;                                // Time stop in bars (32 x M15 = 8h)
input bool   InpFlipOnOpposite = true;                              // Opposite signal closes and reverses
//--- time
input int    InpServerMinusNY  = 7;                                 // Server time minus New York time (hours)
input int    InpEntryStartNY   = 0;                                 // Entries allowed from (NY hour)
input int    InpEntryEndNY     = 24;                                // Entries allowed until (NY hour)
input int    InpFridayFlatNY   = 16;                                // Friday: close all from this NY hour
input int    InpPollSec        = 3;                                 // Command poll interval
input int    InpSlippagePts    = 20;                                // Max slippage in points
//--- module switches (v2)
input bool   InpFxOn           = true;                              // FX SWARM module (25 pairs) on
input bool   InpGoldOn         = false;                             // GOLD module (ATLAS v6 / CENTAUR) on
input int    InpGoldMode       = 1;                                 // GOLD mode: 0 = ATLAS v6 exact, 1 = CENTAUR (v6 + Kimi armor)
input string InpGoldSymbol     = "XAUUSD";                          // Gold symbol (suffix from InpSuffix is added)
input long   InpGoldMagic      = 540001;                            // Gold magic (CENTAUR 540001, ATLAS v6 530006)
input bool   InpGoldAllowLive  = false;                             // Gold refuses REAL accounts unless true (real-order mode only)
input bool   InpGoldPaper      = true;                              // Gold PAPER mode: virtual account, never sends orders
input double InpGoldPaperStart = 10000.0;                           // Paper starting balance (USD)
input double InpGoldPaperComm  = 3.57;                              // Paper commission per lot per side (USD, Pepperstone tester)
//--- GOLD engine = CLAUDE_ATLAS_v6 frozen contest config
input double InpG_TargetVol    = 0.010;                             // daily vol target (fraction)
input double InpG_LevCap       = 2.0;                               // max exposure / equity
input double InpG_GateFrac     = 0.05;                              // size fraction when below D1 EMA100
input int    InpG_EmaD1        = 100;                               // D1 trend EMA period
input int    InpG_AtrD1        = 14;                                // D1 ATR period
input double InpG_StopAtr      = 1.3;                               // disaster stop = ATR * mult
input int    InpG_RebalHour    = 2;                                 // server hour to rebalance
input double InpG_BrakeDD      = 0.08;                              // equity DD to trigger brake
input double InpG_BrakeCut     = 0.5;                               // size multiplier while braked
input int    InpG_VolLook      = 20;                                // realized vol lookback (D1 bars)
input double InpG_MaxSpread    = 60;                                // wait if spread above (max 4 bars)
//--- CENTAUR armor (mode 1 only)
input double InpG_ExplMult     = 2.0;                               // [armor1] M15 ATR explosion multiple
input int    InpG_ExplBars     = 500;                               // ATR explosion: mean window (M15 bars)
input int    InpG_PFWindow     = 60;                                // [armor2] closed trades in PF(R) window
input double InpG_PFTrigger    = 1.00;                              // [armor2] PF(R) below -> derisk
input double InpG_PFRecover    = 1.10;                              // [armor2] PF(R) above -> recover
input double InpG_ThrottleCut  = 0.5;                               // size multiplier while throttled
input double InpG_HardPF       = 0.6;                               // PF below -> hard brake
input int    InpG_HardDays     = 7;                                 // hard brake = token-only days

CTrade   trade;
string   g_base[];
string   g_sym[];
int      g_atr[];
int      g_n        = 0;
datetime g_lastBar  = 0;
datetime g_lastPoll = 0;
long     g_lastCmd  = 0;
string   g_pfx      = "";
string   g_status   = "";

//+------------------------------------------------------------------+
datetime NowNY() { return TimeCurrent() - (datetime)(InpServerMinusNY * 3600); }

int DayIdNY()
{
   MqlDateTime t; TimeToStruct(NowNY(), t);
   return t.year * 10000 + t.mon * 100 + t.day;
}

datetime DayStartServer()
{
   MqlDateTime t; TimeToStruct(NowNY(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   return StructToTime(t) + (datetime)(InpServerMinusNY * 3600);
}

bool InEntryWindow()
{
   MqlDateTime t; TimeToStruct(NowNY(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6) return false;
   if(t.day_of_week == 5 && t.hour >= InpFridayFlatNY) return false;
   return (t.hour >= InpEntryStartNY && t.hour < InpEntryEndNY);
}

bool FridayFlatTime()
{
   MqlDateTime t; TimeToStruct(NowNY(), t);
   return (t.day_of_week == 5 && t.hour >= InpFridayFlatNY);
}

int SymIndex(string base)
{
   for(int i = 0; i < g_n; i++) if(g_base[i] == base) return i;
   return -1;
}

double LastATR(int idx)
{
   double buf[];
   if(CopyBuffer(g_atr[idx], 0, 1, 1, buf) != 1) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Day P/L guard                                                    |
//+------------------------------------------------------------------+
double DayPL(int &tradesToday)
{
   double pl = 0.0;
   tradesToday = 0;
   if(HistorySelect(DayStartServer(), TimeCurrent() + 60))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) tradesToday++;
      }
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

bool DayLocked() { return (GlobalVariableCheck(g_pfx + "LOCK") && (int)GlobalVariableGet(g_pfx + "LOCK") == DayIdNY()); }

int CountMagicPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) c++;
   }
   return c;
}

void CloseAll(string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!trade.PositionClose(tk)) Print("CloseAll fail ", tk, " ", trade.ResultRetcodeDescription());
   }
   Print("CloseAll: ", why);
}

//+------------------------------------------------------------------+
//| Currency exposure: BUY EURUSD = +EUR -USD                        |
//+------------------------------------------------------------------+
int Exposure(string ccy, ulong skipTicket)
{
   int e = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || tk == skipTicket) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string s = StringSubstr(PositionGetString(POSITION_SYMBOL), 0, 6);
      int dir = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(StringSubstr(s, 0, 3) == ccy) e += dir;
      if(StringSubstr(s, 3, 3) == ccy) e -= dir;
   }
   return e;
}

ulong FindPosition(string sym, int &dir)
{
   dir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      dir = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      return tk;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Lot from risk                                                    |
//+------------------------------------------------------------------+
double CalcLot(string sym, double slDist, string &why)
{
   double tv   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(tv <= 0 || ts <= 0 || step <= 0 || slDist <= 0) { why = "bad symbol info"; return 0.0; }
   double lossPerLot = (slDist / ts) * tv;
   double lot = InpRiskUSD / lossPerLot;
   lot = MathFloor(lot / step) * step;
   if(lot < vmin)
   {
      if(vmin * lossPerLot <= InpRiskUSD * InpMinLotRiskMult) lot = vmin;
      else { why = "min lot risk " + DoubleToString(vmin * lossPerLot, 2) + " too big"; return 0.0; }
   }
   lot = MathMin(lot, MathMin(InpMaxLot, vmax));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| OPEN command                                                     |
//+------------------------------------------------------------------+
string DoOpen(string base, int dir, int conf, string &msg)
{
   if(DayLocked())       { msg = "day locked"; return "SKIP"; }
   if(!InEntryWindow())  { msg = "outside entry window"; return "SKIP"; }
   int idx = SymIndex(base);
   if(idx < 0)           { msg = "symbol not in list"; return "SKIP"; }
   string sym = g_sym[idx];

   int curDir = 0;
   ulong cur = FindPosition(sym, curDir);
   if(cur != 0 && curDir == dir) { msg = "already in same direction"; return "SKIP"; }
   if(cur != 0 && !InpFlipOnOpposite) { msg = "opposite open, flip disabled"; return "SKIP"; }

   int open = CountMagicPositions() - (cur != 0 ? 1 : 0);
   if(open >= InpMaxPositions) { msg = "max positions"; return "SKIP"; }

   int tradesToday = 0;
   DayPL(tradesToday);
   if(tradesToday >= InpMaxTradesDay) { msg = "max trades today"; return "SKIP"; }

   string b = StringSubstr(base, 0, 3), q = StringSubstr(base, 3, 3);
   if(MathAbs(Exposure(b, cur) + dir) > InpMaxPerCurrency) { msg = "currency cap " + b; return "SKIP"; }
   if(MathAbs(Exposure(q, cur) - dir) > InpMaxPerCurrency) { msg = "currency cap " + q; return "SKIP"; }

   double atr = LastATR(idx);
   if(atr <= 0) { msg = "no ATR"; return "SKIP"; }
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) { msg = "no price"; return "SKIP"; }
   if(ask - bid > InpMaxSpreadATR * atr) { msg = "spread too wide"; return "SKIP"; }

   string lotWhy = "";
   double lot = CalcLot(sym, InpSL_ATR * atr, lotWhy);
   if(lot <= 0) { msg = lotWhy; return "SKIP"; }

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double price  = (dir > 0) ? ask : bid;
   double sl     = NormalizeDouble(price - dir * InpSL_ATR * atr, digits);
   double tp     = NormalizeDouble(price + dir * InpTP_ATR * atr, digits);
   string side   = (dir > 0) ? "BUY" : "SELL";

   if(InpDryRun)
   {
      msg = "DRY would " + side + " " + sym + " " + DoubleToString(lot, 2) + " @" + DoubleToString(price, digits) +
            " sl " + DoubleToString(sl, digits) + " tp " + DoubleToString(tp, digits) + (cur != 0 ? " (flip)" : "");
      return "DRY";
   }

   if(cur != 0 && !trade.PositionClose(cur)) { msg = "flip close failed " + trade.ResultRetcodeDescription(); return "ERR"; }

   string cmt = "FXSW c" + IntegerToString(conf);
   bool ok = (dir > 0) ? trade.Buy(lot, sym, 0.0, sl, tp, cmt) : trade.Sell(lot, sym, 0.0, sl, tp, cmt);
   if(!ok) { msg = side + " failed " + trade.ResultRetcodeDescription(); return "ERR"; }

   int nd = 0;
   ulong tk = FindPosition(sym, nd);
   if(tk != 0) GlobalVariableSet(g_pfx + "A_" + IntegerToString((long)tk), atr);
   msg = side + " " + sym + " " + DoubleToString(lot, 2) + " ticket " + IntegerToString((long)tk) + (cur != 0 ? " (flip)" : "");
   return "OK";
}

//+------------------------------------------------------------------+
//| Position management: BE, trail, time stop                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym   = PositionGetString(POSITION_SYMBOL);
      int    dir   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      datetime ot  = (datetime)PositionGetInteger(POSITION_TIME);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

      int held = (int)((TimeCurrent() - ot) / PeriodSeconds(InpTF));
      if(held >= InpMaxHoldBars)
      {
         if(trade.PositionClose(tk)) Print("Time stop ", sym, " ", tk);
         continue;
      }

      string gv = g_pfx + "A_" + IntegerToString((long)tk);
      double atr = GlobalVariableCheck(gv) ? GlobalVariableGet(gv) : 0.0;
      if(atr <= 0)
      {
         int idx = SymIndex(StringSubstr(sym, 0, 6));
         if(idx >= 0) atr = LastATR(idx);
         if(atr <= 0) continue;
         GlobalVariableSet(gv, atr);
      }

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double cur = (dir > 0) ? bid : ask;
      double fav = (cur - open) * dir;
      double newSL = sl;

      if(fav >= InpBE_ATR * atr)
      {
         if(dir > 0 && (newSL == 0.0 || newSL < open)) newSL = open;
         if(dir < 0 && (newSL == 0.0 || newSL > open)) newSL = open;
      }
      if(fav >= InpTrailStart_ATR * atr)
      {
         double ts = cur - dir * InpTrailDist_ATR * atr;
         if(dir > 0 && ts > newSL) newSL = ts;
         if(dir < 0 && (newSL == 0.0 || ts < newSL)) newSL = ts;
      }
      newSL = NormalizeDouble(newSL, digits);
      if(newSL == sl) continue;

      bool improve = (sl == 0.0) || ((newSL - sl) * dir >= 0.1 * atr) || (MathAbs(newSL - open) < point && (open - sl) * dir > 0);
      if(!improve) continue;

      double stopsLvl = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if((cur - newSL) * dir <= stopsLvl) continue;

      if(!trade.PositionModify(tk, newSL, tp)) Print("Modify fail ", sym, " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| HTTP                                                             |
//+------------------------------------------------------------------+
int Http(string method, string path, string body, string &resp)
{
   char data[];
   char result[];
   string rh;
   if(StringLen(body) > 0) StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   string headers = "Content-Type: application/json\r\nx-maxx-key: " + InpKey + "\r\n";
   ResetLastError();
   int code = WebRequest(method, InpURL + path, headers, 8000, data, result, rh);
   if(code == -1)
   {
      resp = "";
      Print("WebRequest error ", GetLastError(), " on ", path, " - add the URL in Tools > Options > Expert Advisors");
      return -1;
   }
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
}

string PosJson()
{
   string s = "[";
   bool first = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      string d = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(!first) s += ",";
      first = false;
      s += "{\"s\":\"" + StringSubstr(sym, 0, 6) + "\",\"d\":\"" + d + "\",\"v\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
           ",\"p\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "}";
   }
   return s + "]";
}

void PostBars()
{
   int tradesToday = 0;
   double pl = DayPL(tradesToday);
   string js = "{\"ver\":\"FXSW_v1\",\"dry\":" + (InpDryRun ? "true" : "false") + ",\"locked\":" + (DayLocked() ? "true" : "false") +
               ",\"dayPL\":" + DoubleToString(pl, 2) + ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
               ",\"trades\":" + IntegerToString(tradesToday) + ",\"positions\":" + PosJson() + ",\"pairs\":[";
   int sent = 0;
   for(int k = 0; k < g_n; k++)
   {
      MqlRates r[];
      int got = CopyRates(g_sym[k], InpTF, 1, InpBarsToSend, r);
      if(got < 30) continue;
      double atr = LastATR(k);
      if(atr <= 0) continue;
      int dg = (int)SymbolInfoInteger(g_sym[k], SYMBOL_DIGITS);
      double spr = SymbolInfoDouble(g_sym[k], SYMBOL_ASK) - SymbolInfoDouble(g_sym[k], SYMBOL_BID);
      string t = "", o = "", h = "", l = "", c = "";
      for(int i = 0; i < got; i++)
      {
         string sep = (i == 0) ? "" : ",";
         t += sep + IntegerToString((long)r[i].time);
         o += sep + DoubleToString(r[i].open, dg);
         h += sep + DoubleToString(r[i].high, dg);
         l += sep + DoubleToString(r[i].low, dg);
         c += sep + DoubleToString(r[i].close, dg);
      }
      if(sent > 0) js += ",";
      js += "{\"s\":\"" + g_base[k] + "\",\"d\":" + IntegerToString(dg) + ",\"atr\":" + DoubleToString(atr, dg + 1) +
            ",\"spr\":" + DoubleToString(spr, dg + 1) + ",\"t\":[" + t + "],\"o\":[" + o + "],\"h\":[" + h + "],\"l\":[" + l + "],\"c\":[" + c + "]}";
      sent++;
   }
   js += "]}";
   string resp;
   int code = Http("POST", "/api/bar", js, resp);
   g_status = "bar post " + IntegerToString(code) + " pairs " + IntegerToString(sent) + " " + StringSubstr(resp, 0, 80);
   Print(g_status);
}

void Ack(long id, string st, string msg)
{
   StringReplace(msg, "\"", "'");
   StringReplace(msg, "\\", "/");
   string resp;
   Http("POST", "/api/ack", "{\"id\":" + IntegerToString(id) + ",\"st\":\"" + st + "\",\"msg\":\"" + msg + "\"}", resp);
}

void PollCommands()
{
   string resp;
   int code = Http("GET", "/api/cmd?since=" + IntegerToString(g_lastCmd), "", resp);
   if(code != 200 || StringLen(resp) == 0) return;
   string lines[];
   int n = StringSplit(resp, '\n', lines);
   for(int i = 0; i < n; i++)
   {
      string ln = lines[i];
      StringTrimLeft(ln);
      StringTrimRight(ln);
      if(StringLen(ln) == 0) continue;
      string f[];
      if(StringSplit(ln, ';', f) < 5) continue;
      long id = StringToInteger(f[0]);
      if(id <= g_lastCmd) continue;
      g_lastCmd = id;
      GlobalVariableSet(g_pfx + "LASTCMD", (double)g_lastCmd);
      string msg = "";
      string st  = "SKIP";
      if(f[1] == "OPEN")
      {
         int dir = (f[3] == "BUY") ? 1 : ((f[3] == "SELL") ? -1 : 0);
         if(dir == 0) { msg = "bad dir"; }
         else st = DoOpen(f[2], dir, (int)StringToInteger(f[4]), msg);
      }
      else if(f[1] == "CLOSEALL")
      {
         if(InpDryRun) { st = "DRY"; msg = "would close all"; }
         else { CloseAll("server command"); st = "OK"; msg = "closed all"; }
      }
      else msg = "unknown action";
      Print("CMD #", id, " ", ln, " -> ", st, " ", msg);
      Ack(id, st, msg);
   }
}

//+------------------------------------------------------------------+
//| GOLD MODULE                                                      |
//| Engine = CLAUDE_ATLAS_v6 "FINAL FORM", ported line-for-line:     |
//|   daily 02:00 server rebalance, size = Equity*min(TV/RV20, cap), |
//|   D1 EMA100 gate scales SIZE, gate-off = token touch (1 M15 bar),|
//|   8% HWM brake -> x0.5, disaster stop 1.3 x ATR14(D1), no TP.    |
//| Mode 1 = CENTAUR_v1 (ported line-for-line from the original):    |
//|   armor1 ATR explosion: M15 ATR14 > 2x mean(500) -> token day    |
//|   armor2 PF(R) of last 60 closed trades (all trades, filled via  |
//|          OnTradeTransaction, window resets on restart) < 1.00 -> |
//|          size x0.5 until PF(R) > 1.10                            |
//|   armor3 PF(R) < 0.60 -> token-touch mode for 7 days             |
//|   armor state + HWM use the same GlobalVariable names as         |
//|   CENTAUR_v1 (CENTAUR_<sym>_<magic>_...).                        |
//| Only symbol/magic plumbing differs from the original files.      |
//+------------------------------------------------------------------+
bool     g_fxOn         = true;    // effective switches (tester forces FX off, GOLD on)
bool     g_goldOn       = false;
CTrade   gtrade;
string   g_gSym         = "";
int      g_hEmaD1       = INVALID_HANDLE;
int      g_hAtrD1       = INVALID_HANDLE;
int      g_hAtrM15      = INVALID_HANDLE;
datetime g_gLastBar     = 0;
datetime g_gLastRebal   = 0;
int      g_gSpreadWaits = 0;
string   g_gHwmName     = "";
bool     g_gTokenPos    = false;
datetime g_gEntryBar    = 0;
string   g_gStatus      = "";
string   g_gGv          = "";
datetime g_gLastWatch   = 0;
double   g_rWin[];                  // CENTAUR rolling R window
bool     g_derisked     = false;
datetime g_hbUntil      = 0;
double   g_openRiskMoney = 0.0;

bool IsTester() { return (MQLInfoInteger(MQL_TESTER) != 0 || MQLInfoInteger(MQL_OPTIMIZATION) != 0); }
string GoldLabel() { return (InpGoldMode == 1) ? "CENTAUR" : "ATLAS_v6"; }

bool GoldNewBar()
{
   datetime t = iTime(g_gSym, PERIOD_M15, 0);
   if(t == 0 || t == g_gLastBar) return false;
   g_gLastBar = t;
   return true;
}

double GoldRV()
{
   int need = InpG_VolLook + 2;
   double c[];
   if(CopyClose(g_gSym, PERIOD_D1, 1, need, c) < need) return -1.0;
   ArraySetAsSeries(c, true);
   double sum = 0.0, sum2 = 0.0;
   int n = 0;
   for(int i = 0; i < InpG_VolLook; i++)
   {
      double r = c[i] / c[i + 1] - 1.0;
      sum += r; sum2 += r * r; n++;
   }
   if(n < InpG_VolLook) return -1.0;
   double mean = sum / n;
   double var  = sum2 / n - mean * mean;
   if(var <= 0.0) return -1.0;
   return MathSqrt(var);
}

bool GoldD1(double &ema, double &atr)
{
   double be[], ba[];
   if(CopyBuffer(g_hEmaD1, 0, 1, 1, be) < 1) return false;
   if(CopyBuffer(g_hAtrD1, 0, 1, 1, ba) < 1) return false;
   ema = be[0]; atr = ba[0];
   return (ema > 0 && atr > 0);
}

ulong GoldPos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_gSym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpGoldMagic) continue;
      return tk;
   }
   return 0;
}

void GoldClosePos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_gSym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpGoldMagic) continue;
      gtrade.PositionClose(tk);
   }
}

double GoldNormLot(double lot)
{
   double minLot  = SymbolInfoDouble(g_gSym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_gSym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(g_gSym, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

//--- CENTAUR armor (a): ATR explosion on M15
bool GoldExplosion()
{
   double nowBuf[];
   if(CopyBuffer(g_hAtrM15, 0, 1, 1, nowBuf) < 1) return false;
   double atrNow = nowBuf[0];
   if(atrNow <= 0.0) return false;
   double hist[];
   int copied = CopyBuffer(g_hAtrM15, 0, 1, InpG_ExplBars, hist);
   if(copied < InpG_ExplBars) return false;
   double sum = 0.0;
   for(int i = 0; i < copied; i++) sum += hist[i];
   double avg = sum / (double)copied;
   if(avg <= 0.0) return false;
   return (atrNow > InpG_ExplMult * avg);
}

//--- CENTAUR_v1 armor2/3 (verbatim logic)
string CenGV(const string suffix) { return (GP() ? "CENPAPER_" : "CENTAUR_") + g_gSym + "_" + IntegerToString((int)InpGoldMagic) + "_" + suffix; }
void CenPersist()
{
   if(InpGoldMode != 1) return;
   GlobalVariableSet(CenGV("DERISK"),   g_derisked ? 1.0 : 0.0);
   GlobalVariableSet(CenGV("HBUNTIL"),  (double)g_hbUntil);
   GlobalVariableSet(CenGV("OPENRISK"), g_openRiskMoney);
}
void CenLoad()
{
   if(GlobalVariableCheck(CenGV("DERISK")))   g_derisked = (GlobalVariableGet(CenGV("DERISK")) != 0.0);
   if(GlobalVariableCheck(CenGV("HBUNTIL")))  g_hbUntil = (datetime)GlobalVariableGet(CenGV("HBUNTIL"));
   if(GlobalVariableCheck(CenGV("OPENRISK"))) g_openRiskMoney = GlobalVariableGet(CenGV("OPENRISK"));
}
double CenRollingPF()
{
   int n = ArraySize(g_rWin);
   if(n == 0) return 0.0;
   double gp = 0.0, gl = 0.0;
   for(int i = 0; i < n; i++)
   {
      if(g_rWin[i] > 0.0) gp += g_rWin[i];
      else                gl += -g_rWin[i];
   }
   if(gl <= 0.0) return (gp > 0.0 ? DBL_MAX : 1.0);
   return gp / gl;
}
void CenAddClosedR(const double r)
{
   int sz = ArraySize(g_rWin);
   if(sz < InpG_PFWindow)
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
void CenEvaluateArmor()
{
   if(ArraySize(g_rWin) < InpG_PFWindow) return;   // wait for a full window
   double pf = CenRollingPF();
   if(pf < InpG_HardPF)
   {
      g_hbUntil = TimeCurrent() + (datetime)InpG_HardDays * 86400;
      Print("CENTAUR [HardBrake] PF(R)=", DoubleToString(pf, 2), " -> token-touch mode until ", TimeToString(g_hbUntil));
   }
   if(!g_derisked && pf < InpG_PFTrigger)
   {
      g_derisked = true;
      Print("CENTAUR [Throttle] DE-RISK ON: PF(R)=", DoubleToString(pf, 2));
   }
   else if(g_derisked && pf > InpG_PFRecover)
   {
      g_derisked = false;
      Print("CENTAUR [Throttle] DE-RISK OFF: PF(R)=", DoubleToString(pf, 2));
   }
   CenPersist();
}

void CenOnClosed(const double pnl)
{
   if(InpGoldMode != 1) return;
   if(g_openRiskMoney > 0.0)
   {
      CenAddClosedR(pnl / g_openRiskMoney);
      g_openRiskMoney = 0.0;
      CenEvaluateArmor();
   }
   CenPersist();
}

//+------------------------------------------------------------------+
//| PAPER MODE (default): CENTAUR runs on a virtual $ account inside |
//| this EA. It reads real XAUUSD prices but never sends an order,   |
//| so it can share the VPS account with anything else. Sizing uses  |
//| the virtual equity; fills at real ask/bid; SL checked every      |
//| second + bar lows; swap from the symbol's real swap settings;    |
//| commission per lot per side. Close events reach the armor in the |
//| same order MT5 delivers them (after the handler returns).        |
//+------------------------------------------------------------------+
bool     g_pOpen     = false;
double   g_pLot      = 0.0;
double   g_pEntry    = 0.0;
double   g_pSL       = 0.0;
datetime g_pOTime    = 0;
long     g_pPosId    = 0;
double   g_pBal      = 0.0;
double   g_pSwapAcc  = 0.0;
datetime g_pSwapDay  = 0;
double   g_pPend[];                 // close P/L waiting for the "transaction" step
long     g_dT[];  long g_dPos[]; string g_dE[]; double g_dV[]; double g_dPx[]; double g_dPl[]; double g_dSw[]; double g_dCm[];
int      g_dN        = 0;

bool   GP() { return InpGoldPaper && !IsTester(); }
string PGV(const string s) { return "CENP_" + IntegerToString((int)InpGoldMagic) + "_" + s; }
string PaperFile() { return "CENTAUR_PAPER_" + IntegerToString((int)InpGoldMagic) + ".csv"; }

void PaperSave()
{
   GlobalVariableSet(PGV("OPEN"), g_pOpen ? 1.0 : 0.0);
   GlobalVariableSet(PGV("LOT"), g_pLot);
   GlobalVariableSet(PGV("ENTRY"), g_pEntry);
   GlobalVariableSet(PGV("SL"), g_pSL);
   GlobalVariableSet(PGV("OTIME"), (double)g_pOTime);
   GlobalVariableSet(PGV("POSID"), (double)g_pPosId);
   GlobalVariableSet(PGV("BAL"), g_pBal);
   GlobalVariableSet(PGV("SWAPACC"), g_pSwapAcc);
   GlobalVariableSet(PGV("SWAPDAY"), (double)g_pSwapDay);
   GlobalVariableSet(PGV("TOKEN"), g_gTokenPos ? 1.0 : 0.0);
   GlobalVariableSet(PGV("ENTRYBAR"), (double)g_gEntryBar);
   GlobalVariableSet(PGV("LASTREBAL"), (double)g_gLastRebal);
}

void PaperAddDeal(datetime t, long pos, string e, double v, double px, double pl, double sw, double cm)
{
   ArrayResize(g_dT, g_dN + 1); ArrayResize(g_dPos, g_dN + 1); ArrayResize(g_dE, g_dN + 1); ArrayResize(g_dV, g_dN + 1);
   ArrayResize(g_dPx, g_dN + 1); ArrayResize(g_dPl, g_dN + 1); ArrayResize(g_dSw, g_dN + 1); ArrayResize(g_dCm, g_dN + 1);
   g_dT[g_dN] = (long)t; g_dPos[g_dN] = pos; g_dE[g_dN] = e; g_dV[g_dN] = v; g_dPx[g_dN] = px; g_dPl[g_dN] = pl; g_dSw[g_dN] = sw; g_dCm[g_dN] = cm;
   g_dN++;
   int fh = FileOpen(PaperFile(), FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh != INVALID_HANDLE)
   {
      FileSeek(fh, 0, SEEK_END);
      FileWriteString(fh, IntegerToString((long)t) + "," + IntegerToString(pos) + "," + e + "," + DoubleToString(v, 2) + "," +
                      DoubleToString(px, 3) + "," + DoubleToString(pl, 2) + "," + DoubleToString(sw, 2) + "," + DoubleToString(cm, 2) + "\n");
      FileClose(fh);
   }
}

void PaperLoad()
{
   g_pOpen    = GlobalVariableCheck(PGV("OPEN")) && GlobalVariableGet(PGV("OPEN")) > 0.5;
   g_pLot     = GlobalVariableCheck(PGV("LOT")) ? GlobalVariableGet(PGV("LOT")) : 0.0;
   g_pEntry   = GlobalVariableCheck(PGV("ENTRY")) ? GlobalVariableGet(PGV("ENTRY")) : 0.0;
   g_pSL      = GlobalVariableCheck(PGV("SL")) ? GlobalVariableGet(PGV("SL")) : 0.0;
   g_pOTime   = GlobalVariableCheck(PGV("OTIME")) ? (datetime)GlobalVariableGet(PGV("OTIME")) : 0;
   g_pPosId   = GlobalVariableCheck(PGV("POSID")) ? (long)GlobalVariableGet(PGV("POSID")) : 0;
   g_pBal     = GlobalVariableCheck(PGV("BAL")) ? GlobalVariableGet(PGV("BAL")) : InpGoldPaperStart;
   g_pSwapAcc = GlobalVariableCheck(PGV("SWAPACC")) ? GlobalVariableGet(PGV("SWAPACC")) : 0.0;
   g_pSwapDay = GlobalVariableCheck(PGV("SWAPDAY")) ? (datetime)GlobalVariableGet(PGV("SWAPDAY")) : 0;
   g_gTokenPos  = GlobalVariableCheck(PGV("TOKEN")) && GlobalVariableGet(PGV("TOKEN")) > 0.5;
   g_gEntryBar  = GlobalVariableCheck(PGV("ENTRYBAR")) ? (datetime)GlobalVariableGet(PGV("ENTRYBAR")) : 0;
   g_gLastRebal = GlobalVariableCheck(PGV("LASTREBAL")) ? (datetime)GlobalVariableGet(PGV("LASTREBAL")) : 0;
   if(!GlobalVariableCheck(PGV("START"))) GlobalVariableSet(PGV("START"), (double)TimeCurrent());
   g_dN = 0;
   int fh = FileOpen(PaperFile(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   while(!FileIsEnding(fh))
   {
      string ln = FileReadString(fh);
      string f[];
      if(StringSplit(ln, ',', f) < 8) continue;
      ArrayResize(g_dT, g_dN + 1); ArrayResize(g_dPos, g_dN + 1); ArrayResize(g_dE, g_dN + 1); ArrayResize(g_dV, g_dN + 1);
      ArrayResize(g_dPx, g_dN + 1); ArrayResize(g_dPl, g_dN + 1); ArrayResize(g_dSw, g_dN + 1); ArrayResize(g_dCm, g_dN + 1);
      g_dT[g_dN] = StringToInteger(f[0]); g_dPos[g_dN] = StringToInteger(f[1]); g_dE[g_dN] = f[2]; g_dV[g_dN] = StringToDouble(f[3]);
      g_dPx[g_dN] = StringToDouble(f[4]); g_dPl[g_dN] = StringToDouble(f[5]); g_dSw[g_dN] = StringToDouble(f[6]); g_dCm[g_dN] = StringToDouble(f[7]);
      g_dN++;
   }
   FileClose(fh);
}

double PaperSwapPerLotNight()
{
   int mode = (int)SymbolInfoInteger(g_gSym, SYMBOL_SWAP_MODE);
   double sw = SymbolInfoDouble(g_gSym, SYMBOL_SWAP_LONG);
   if(mode == SYMBOL_SWAP_MODE_POINTS)
   {
      double pt = SymbolInfoDouble(g_gSym, SYMBOL_POINT), ts = SymbolInfoDouble(g_gSym, SYMBOL_TRADE_TICK_SIZE), tv = SymbolInfoDouble(g_gSym, SYMBOL_TRADE_TICK_VALUE);
      return (ts > 0) ? sw * pt / ts * tv : 0.0;
   }
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL || mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT || mode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN) return sw;
   if(mode == SYMBOL_SWAP_MODE_INTEREST_CURRENT || mode == SYMBOL_SWAP_MODE_INTEREST_OPEN)
      return SymbolInfoDouble(g_gSym, SYMBOL_BID) * SymbolInfoDouble(g_gSym, SYMBOL_TRADE_CONTRACT_SIZE) * sw / 100.0 / 360.0;
   return 0.0;
}

void PaperAccrueSwap()
{
   if(!g_pOpen) return;
   datetime day = iTime(g_gSym, PERIOD_D1, 0);
   if(day <= 0 || day == g_pSwapDay) return;
   MqlDateTime prev;
   TimeToStruct(g_pSwapDay, prev);
   int mult = (prev.day_of_week == (int)SymbolInfoInteger(g_gSym, SYMBOL_SWAP_ROLLOVER3DAYS)) ? 3 : 1;
   g_pSwapAcc += PaperSwapPerLotNight() * g_pLot * mult;
   g_pSwapDay = day;
   PaperSave();
}

double PaperFloating()
{
   if(!g_pOpen) return 0.0;
   double bid = SymbolInfoDouble(g_gSym, SYMBOL_BID);
   return (bid - g_pEntry) * g_pLot * SymbolInfoDouble(g_gSym, SYMBOL_TRADE_CONTRACT_SIZE) + g_pSwapAcc;
}
double PaperEquity() { return g_pBal + PaperFloating(); }

// close at price; deferred=true -> armor sees it after the handler (like OnTradeTransaction), false -> now
void PaperClose(double price, string why, bool deferred)
{
   if(!g_pOpen) return;
   double contract = SymbolInfoDouble(g_gSym, SYMBOL_TRADE_CONTRACT_SIZE);
   double pl = (price - g_pEntry) * g_pLot * contract;
   double cm = -InpGoldPaperComm * g_pLot;
   double sw = g_pSwapAcc;
   double net = pl + sw + cm;
   g_pBal += net;
   PaperAddDeal(TimeCurrent(), g_pPosId, "out", g_pLot, price, pl, sw, cm);
   g_pOpen = false; g_pSwapAcc = 0.0;
   Print("GOLD paper close ", why, " @", DoubleToString(price, 2), " net ", DoubleToString(net, 2), " bal ", DoubleToString(g_pBal, 2));
   if(deferred) { int n = ArraySize(g_pPend); ArrayResize(g_pPend, n + 1); g_pPend[n] = net; }
   else CenOnClosed(net);
   PaperSave();
}

bool PaperOpen(double lot, double ask, double sl)
{
   if(g_pOpen) return false;
   double cm = -InpGoldPaperComm * lot;
   g_pBal += cm;
   g_pPosId++;
   g_pOpen = true; g_pLot = lot; g_pEntry = ask; g_pSL = sl; g_pOTime = TimeCurrent();
   g_pSwapAcc = 0.0; g_pSwapDay = iTime(g_gSym, PERIOD_D1, 0);
   PaperAddDeal(TimeCurrent(), g_pPosId, "in", lot, ask, 0.0, 0.0, cm);
   PaperSave();
   return true;
}

// stop-loss: every call by price, and on each new M15 bar by the closed bar's low
void PaperCheckSL(bool newBar)
{
   if(!g_pOpen || g_pSL <= 0.0) return;
   double bid = SymbolInfoDouble(g_gSym, SYMBOL_BID);
   bool hit = (bid > 0 && bid <= g_pSL);
   if(!hit && newBar && iTime(g_gSym, PERIOD_M15, 1) >= g_pOTime) hit = (iLow(g_gSym, PERIOD_M15, 1) <= g_pSL);
   if(hit) PaperClose(g_pSL, "stop-loss", false);
}

void PaperFlush()
{
   int n = ArraySize(g_pPend);
   for(int i = 0; i < n; i++) CenOnClosed(g_pPend[i]);
   ArrayResize(g_pPend, 0);
}

void GoldReport(string what)
{
   g_gStatus = what;
   Print("GOLD ", GoldLabel(), " ", what);
   if(IsTester() || StringFind(InpURL, "http") != 0) return;
   string resp;
   string m = what;
   StringReplace(m, "\"", "'");
   Http("POST", "/api/gold", "{\"label\":\"" + GoldLabel() + "\",\"magic\":" + IntegerToString(InpGoldMagic) +
        ",\"t\":" + IntegerToString((long)TimeCurrent()) + ",\"msg\":\"" + m + "\"}", resp);
}

datetime g_gDiagDay = 0;
void GoldDiag(string why)
{
   datetime d = iTime(g_gSym, PERIOD_D1, 0);
   if(d == g_gDiagDay) return;          // one message per day
   g_gDiagDay = d;
   Print("GOLD skip ", TimeToString(TimeCurrent()), ": ", why);
}
void GoldRebalance()
{
   double ema, atr;
   if(!GoldD1(ema, atr)) { GoldDiag("D1 EMA/ATR not ready (need ~100 D1 bars of history)"); return; }
   double rv = GoldRV();
   if(rv <= 0.0) { GoldDiag("realized vol not ready"); return; }

   // spread guard: wait up to 4 M15 bars, then force (must trade daily)
   double spreadPts = (double)SymbolInfoInteger(g_gSym, SYMBOL_SPREAD);
   if(spreadPts > InpG_MaxSpread && g_gSpreadWaits < 4)
   {
      g_gSpreadWaits++;
      return;
   }
   g_gSpreadWaits = 0;

   if(GP()) PaperClose(SymbolInfoDouble(g_gSym, SYMBOL_BID), "rebalance", true);
   else GoldClosePos();

   double equity = GP() ? PaperEquity() : AccountInfoDouble(ACCOUNT_EQUITY);
   double hwm = GlobalVariableGet(g_gHwmName);
   if(equity > hwm) { hwm = equity; GlobalVariableSet(g_gHwmName, hwm); }

   double lev = InpG_TargetVol / rv;
   if(lev > InpG_LevCap) lev = InpG_LevCap;

   double closeD1 = iClose(g_gSym, PERIOD_D1, 1);
   bool gateOn = (closeD1 > ema);

   bool token = !gateOn;
   string armor = "";
   if(InpGoldMode == 1)
   {
      if(GoldExplosion())          { token = true; armor += " ATR-explosion"; }   // armor 1
      if(TimeCurrent() < g_hbUntil) { token = true; armor += " hard-brake"; }      // armor 3
   }
   double frac = token ? InpG_GateFrac : 1.0;
   if(hwm > 0 && (1.0 - equity / hwm) > InpG_BrakeDD) frac *= InpG_BrakeCut;
   if(InpGoldMode == 1 && g_derisked) { frac *= InpG_ThrottleCut; armor += " PF-throttle"; }   // armor 2
   if(InpGoldMode == 1) armor += " pfR=" + (ArraySize(g_rWin) > 0 ? DoubleToString(MathMin(CenRollingPF(), 99.0), 2) : "-") + "(" + IntegerToString(ArraySize(g_rWin)) + ")";

   double ask = SymbolInfoDouble(g_gSym, SYMBOL_ASK);
   if(ask <= 0) return;

   double contract = SymbolInfoDouble(g_gSym, SYMBOL_TRADE_CONTRACT_SIZE);
   double oz  = equity * lev * frac / ask;
   double lot = GoldNormLot(oz / contract);
   int digits = (int)SymbolInfoInteger(g_gSym, SYMBOL_DIGITS);
   double sl = NormalizeDouble(ask - InpG_StopAtr * atr, digits);

   string desc = (gateOn ? "gate ON" : "gate OFF") + (token ? " TOKEN" : " FULL") +
                 " lot " + DoubleToString(lot, 2) + " rv " + DoubleToString(rv * 100, 2) + "% lev " + DoubleToString(lev, 2) +
                 " frac " + DoubleToString(frac, 3) + " eq " + DoubleToString(equity, 0) + " hwm " + DoubleToString(hwm, 0) + armor;

   bool opened = GP() ? PaperOpen(lot, ask, sl) : gtrade.Buy(lot, g_gSym, 0.0, sl, 0.0, (InpGoldMode == 1 ? "CENTAUR daily" : "ATLAS6 daily"));
   if(!opened)
      GoldReport("BUY FAILED err " + IntegerToString(GetLastError()) + " | " + desc);
   else
   {
      g_gTokenPos = token;                                   // token day = touch, exit next M15 bar
      g_gEntryBar = iTime(g_gSym, PERIOD_M15, 0);
      if(InpGoldMode == 1)
      {
         g_openRiskMoney = lot * contract * (ask - sl);   // for R at close
         CenPersist();
      }
      GoldReport((GP() ? "[paper] " : "") + desc);
   }
   g_gLastRebal = iTime(g_gSym, PERIOD_D1, 0);
   if(GP()) PaperSave();
}

// same flow as the original OnTick(), driven by new M15 bars of the gold symbol
void GoldStep()
{
   if(!g_goldOn || g_gSym == "") return;
   if(GP()) { PaperAccrueSwap(); PaperCheckSL(false); }
   if(!GoldNewBar()) return;
   if(GP()) PaperCheckSL(true);

   bool hasPos = GP() ? g_pOpen : (GoldPos() != 0);
   if(g_gTokenPos && hasPos && iTime(g_gSym, PERIOD_M15, 0) > g_gEntryBar)
   {
      if(GP()) PaperClose(SymbolInfoDouble(g_gSym, SYMBOL_BID), "token exit", true);
      else
      {
         ulong tk = GoldPos();
         if(tk != 0) gtrade.PositionClose(tk);
      }
      g_gTokenPos = false;
   }

   MqlDateTime st;
   TimeToStruct(iTime(g_gSym, PERIOD_M15, 0), st);
   datetime today = iTime(g_gSym, PERIOD_D1, 0);
   bool doneToday = (g_gLastRebal == today);
   if(!doneToday && st.hour >= InpG_RebalHour)
      GoldRebalance();
   if(GP()) { PaperFlush(); PaperSave(); }
}

// read-only report of the gold soldier to the dashboard (same format as MAXX_WATCH)
string GoldDealsJson()
{
   string s = "[";
   bool first = true;
   if(!HistorySelect(TimeCurrent() - 400 * 86400, TimeCurrent() + 3600)) return "[]";
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpGoldMagic) continue;
      ENUM_DEAL_TYPE ty = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
      if(ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL) continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(!first) s += ",";
      first = false;
      s += "{\"t\":" + IntegerToString((long)HistoryDealGetInteger(d, DEAL_TIME)) +
           ",\"pos\":" + IntegerToString((long)HistoryDealGetInteger(d, DEAL_POSITION_ID)) +
           ",\"e\":\"" + (en == DEAL_ENTRY_IN ? "in" : "out") + "\",\"d\":\"" + (ty == DEAL_TYPE_BUY ? "B" : "S") + "\"" +
           ",\"sym\":\"" + HistoryDealGetString(d, DEAL_SYMBOL) + "\"" +
           ",\"v\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_VOLUME), 2) +
           ",\"px\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), 3) +
           ",\"pl\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PROFIT), 2) +
           ",\"sw\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_SWAP), 2) +
           ",\"cm\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_COMMISSION), 2) + "}";
   }
   return s + "]";
}

string PaperDealsJson()
{
   string s = "[";
   int from = MathMax(0, g_dN - 1500);
   for(int i = from; i < g_dN; i++)
   {
      if(i > from) s += ",";
      s += "{\"t\":" + IntegerToString(g_dT[i]) + ",\"pos\":" + IntegerToString(g_dPos[i]) + ",\"e\":\"" + g_dE[i] + "\",\"d\":\"" + (g_dE[i] == "in" ? "B" : "S") + "\"" +
           ",\"sym\":\"" + g_gSym + "\",\"v\":" + DoubleToString(g_dV[i], 2) + ",\"px\":" + DoubleToString(g_dPx[i], 3) +
           ",\"pl\":" + DoubleToString(g_dPl[i], 2) + ",\"sw\":" + DoubleToString(g_dSw[i], 2) + ",\"cm\":" + DoubleToString(g_dCm[i], 2) + "}";
   }
   return s + "]";
}

void GoldWatchPush()
{
   if(!g_goldOn || IsTester() || StringFind(InpURL, "http") != 0) return;
   if(TimeCurrent() - g_gLastWatch < 300) return;
   g_gLastWatch = TimeCurrent();
   bool paper = GP();
   double fl = 0.0;
   string opn = "[";
   if(paper)
   {
      if(g_pOpen)
      {
         fl = PaperFloating();
         opn += "{\"sym\":\"" + g_gSym + "\",\"d\":\"B\",\"v\":" + DoubleToString(g_pLot, 2) + ",\"t\":" + IntegerToString((long)g_pOTime) +
                ",\"sl\":" + DoubleToString(g_pSL, 3) + ",\"pl\":" + DoubleToString(fl, 2) + "}";
      }
   }
   else
   {
      ulong tk = GoldPos();
      if(tk != 0 && PositionSelectByTicket(tk))
      {
         fl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         opn += "{\"sym\":\"" + g_gSym + "\",\"d\":\"B\",\"v\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
                ",\"t\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME)) + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), 3) +
                ",\"pl\":" + DoubleToString(fl, 2) + "}";
      }
   }
   opn += "]";
   double startBal = paper ? InpGoldPaperStart : (GlobalVariableCheck(g_gGv + "STARTBAL") ? GlobalVariableGet(g_gGv + "STARTBAL") : AccountInfoDouble(ACCOUNT_BALANCE));
   double startT   = paper ? GlobalVariableGet(PGV("START")) : (GlobalVariableCheck(g_gGv + "STARTT") ? GlobalVariableGet(g_gGv + "STARTT") : (double)TimeCurrent());
   double bal = paper ? g_pBal : AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = paper ? PaperEquity() : AccountInfoDouble(ACCOUNT_EQUITY);
   string js = "{\"acct\":\"" + (paper ? "PAPER" : IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))) + "\"" +
               ",\"server\":\"" + AccountInfoString(ACCOUNT_SERVER) + "\"" +
               ",\"demo\":" + ((paper || AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO) ? "true" : "false") +
               ",\"paper\":" + (paper ? "true" : "false") +
               ",\"now\":" + IntegerToString((long)TimeCurrent()) + ",\"start\":" + IntegerToString((long)startT) +
               ",\"startBal\":" + DoubleToString(startBal, 2) +
               ",\"balance\":" + DoubleToString(bal, 2) + ",\"equity\":" + DoubleToString(eq, 2) +
               ",\"soldiers\":[{\"label\":\"" + GoldLabel() + "\",\"magic\":" + IntegerToString(InpGoldMagic) +
               ",\"floating\":" + DoubleToString(fl, 2) + ",\"open\":" + opn + ",\"deals\":" + (paper ? PaperDealsJson() : GoldDealsJson()) + "}]}";
   string resp;
   Http("POST", "/api/watch", js, resp);
}

bool GoldInit()
{
   if(!g_goldOn) return true;
   if(!IsTester() && !InpGoldPaper && !InpGoldAllowLive && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("GOLD: REAL account blocked. Set InpGoldAllowLive=true to override.");
      return false;
   }
   g_gSym = InpGoldSymbol + InpSuffix;
   if(!SymbolSelect(g_gSym, true)) { Print("GOLD: symbol not found ", g_gSym); return false; }
   gtrade.SetExpertMagicNumber((ulong)InpGoldMagic);
   gtrade.SetDeviationInPoints(50);
   g_hEmaD1  = iMA(g_gSym, PERIOD_D1, InpG_EmaD1, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrD1  = iATR(g_gSym, PERIOD_D1, InpG_AtrD1);
   g_hAtrM15 = iATR(g_gSym, PERIOD_M15, 14);
   if(g_hEmaD1 == INVALID_HANDLE || g_hAtrD1 == INVALID_HANDLE || g_hAtrM15 == INVALID_HANDLE) { Print("GOLD: indicator handle failed"); return false; }
   // same HWM global-variable name as CLAUDE_ATLAS_v6 so a running test keeps its high-water mark
   g_gHwmName = GP() ? PGV("HWM") : ((InpGoldMode == 1) ? CenGV("HWM") : "ATLAS_HWM_" + g_gSym + "_" + IntegerToString((int)InpGoldMagic));
   if(GP()) PaperLoad();
   if(!GlobalVariableCheck(g_gHwmName)) GlobalVariableSet(g_gHwmName, GP() ? PaperEquity() : AccountInfoDouble(ACCOUNT_EQUITY));
   ArrayResize(g_rWin, 0);   // R window starts empty after restart (as CENTAUR_v1)
   if(InpGoldMode == 1) CenLoad();
   g_gGv = "CEN_" + IntegerToString((int)InpGoldMagic) + "_";
   if(!GlobalVariableCheck(g_gGv + "STARTBAL")) GlobalVariableSet(g_gGv + "STARTBAL", AccountInfoDouble(ACCOUNT_BALANCE));
   if(!GlobalVariableCheck(g_gGv + "STARTT")) GlobalVariableSet(g_gGv + "STARTT", (double)TimeCurrent());
   Print("GOLD module ", GoldLabel(), (GP() ? " [PAPER bal " + DoubleToString(g_pBal, 2) + (g_pOpen ? " open " + DoubleToString(g_pLot, 2) : "") + "]" : " [REAL ORDERS]"), " on ", g_gSym, " magic ", InpGoldMagic, (IsTester() ? " [tester: no HTTP]" : ""));
   return true;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_fxOn   = InpFxOn;
   g_goldOn = InpGoldOn;
   if(IsTester())
   {
      // FX module needs the live server + AI and cannot run in the Strategy Tester
      if(g_fxOn) Print("TESTER: FX module disabled automatically (needs live server)");
      g_fxOn = false;
      if(!g_goldOn) Print("TESTER: GOLD module enabled automatically");
      g_goldOn = true;
      if(_Symbol != InpGoldSymbol + InpSuffix) Print("TESTER WARNING: tester symbol is ", _Symbol, " - select ", InpGoldSymbol + InpSuffix, " in the tester for correct results");
   }
   if(StringFind(InpURL, "http") != 0 && g_fxOn && !IsTester()) { Print("Set InpURL to your Railway URL (starting with https)"); return INIT_PARAMETERS_INCORRECT; }
   if(!g_fxOn && !g_goldOn) { Print("Both modules are off"); return INIT_PARAMETERS_INCORRECT; }
   if(!GoldInit()) return INIT_FAILED;
   g_pfx = "FXSW_" + IntegerToString(InpMagic) + "_";
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);

   string parts[];
   int n = g_fxOn ? StringSplit(InpSymbols, ',', parts) : 0;
   ArrayResize(g_base, 0); ArrayResize(g_sym, 0); ArrayResize(g_atr, 0);
   g_n = 0;
   for(int i = 0; i < n; i++)
   {
      string b = parts[i];
      StringTrimLeft(b);
      StringTrimRight(b);
      StringToUpper(b);
      if(StringLen(b) < 6) continue;
      string s = b + InpSuffix;
      if(!SymbolSelect(s, true)) { Print("Symbol not found: ", s); continue; }
      int h = iATR(s, InpTF, InpATRPeriod);
      if(h == INVALID_HANDLE) { Print("ATR handle failed: ", s); continue; }
      ArrayResize(g_base, g_n + 1); ArrayResize(g_sym, g_n + 1); ArrayResize(g_atr, g_n + 1);
      g_base[g_n] = b; g_sym[g_n] = s; g_atr[g_n] = h;
      g_n++;
   }
   if(g_fxOn && g_n == 0) { Print("No symbols loaded - check InpSymbols / InpSuffix"); return INIT_FAILED; }

   if(GlobalVariableCheck(g_pfx + "LASTCMD")) g_lastCmd = (long)GlobalVariableGet(g_pfx + "LASTCMD");

   // clean ATR memory of closed tickets
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string nm = GlobalVariableName(i);
      if(StringFind(nm, g_pfx + "A_") != 0) continue;
      ulong tk = (ulong)StringToInteger(StringSubstr(nm, StringLen(g_pfx) + 2));
      if(!PositionSelectByTicket(tk)) GlobalVariableDel(nm);
   }

   EventSetTimer(1);
   Print("MAXX FX SWARM v2 | FX ", (g_fxOn ? "on " + IntegerToString(g_n) + " pairs" : "off"), " DryRun=", InpDryRun, " | GOLD ", (g_goldOn ? GoldLabel() : "off"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_n; i++) IndicatorRelease(g_atr[i]);
   if(g_goldOn) CenPersist();
   if(g_hEmaD1 != INVALID_HANDLE) IndicatorRelease(g_hEmaD1);
   if(g_hAtrD1 != INVALID_HANDLE) IndicatorRelease(g_hAtrD1);
   if(g_hAtrM15 != INVALID_HANDLE) IndicatorRelease(g_hAtrM15);
   Comment("");
}

void OnTick() { GoldStep(); }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(!g_goldOn || InpGoldMode != 1 || GP()) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpGoldMagic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_gSym) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;
   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(g_openRiskMoney > 0.0)
   {
      CenAddClosedR(pnl / g_openRiskMoney);
      g_openRiskMoney = 0.0;
      CenEvaluateArmor();
   }
   CenPersist();
}

void OnTimer()
{
   GoldStep();
   GoldWatchPush();
   if(!g_fxOn) { Comment("MAXX v2 | GOLD ", GoldLabel(), (GP() ? " PAPER eq " + DoubleToString(PaperEquity(), 2) : ""), " | ", g_gStatus); return; }
   // 1) day guard
   int tradesToday = 0;
   double pl = DayPL(tradesToday);
   if(!DayLocked() && (pl <= -InpDayLossUSD || pl >= InpDayProfitUSD))
   {
      GlobalVariableSet(g_pfx + "LOCK", (double)DayIdNY());
      CloseAll("day limit hit " + DoubleToString(pl, 2));
   }
   if(DayLocked() && CountMagicPositions() > 0) CloseAll("day locked");
   if(FridayFlatTime() && CountMagicPositions() > 0) CloseAll("friday flat");

   // 2) manage open trades
   ManagePositions();

   // 3) new closed bar -> post snapshot (3s after the bar opens)
   datetime t0 = iTime(g_sym[0], InpTF, 0);
   if(t0 > 0 && t0 != g_lastBar && TimeCurrent() - t0 >= 3)
   {
      g_lastBar = t0;
      PostBars();
   }

   // 4) poll commands
   if(TimeCurrent() - g_lastPoll >= InpPollSec)
   {
      g_lastPoll = TimeCurrent();
      PollCommands();
   }

   Comment("MAXX FX SWARM v2  ", (InpDryRun ? "[DRY RUN]" : "[LIVE]"), (g_goldOn ? "  | GOLD " + GoldLabel() + ": " + g_gStatus : ""),
           "\nPairs ", g_n, " | Positions ", CountMagicPositions(), "/", InpMaxPositions,
           " | Trades today ", tradesToday, "/", InpMaxTradesDay,
           "\nDay P/L ", DoubleToString(pl, 2), "  (stop -", DoubleToString(InpDayLossUSD, 0), " / +", DoubleToString(InpDayProfitUSD, 0), ")",
           (DayLocked() ? "  LOCKED" : ""),
           "\nEntry window ", (InEntryWindow() ? "OPEN" : "closed"), " | last cmd #", g_lastCmd,
           "\n", g_status);
}
//+------------------------------------------------------------------+
