//+------------------------------------------------------------------+
//| MaxxFxSwarm_v1.mq5                                               |
//| MAXX FX SWARM - EA hands for the AI server (25 FX pairs, M15)    |
//| EA posts closed bars -> server asks AI -> EA polls commands.     |
//| All money rules live HERE, the AI only picks pair + direction.   |
//+------------------------------------------------------------------+
#property copyright "MAXX"
#property version   "1.00"
#property description "MAXX FX SWARM v1 - AI picks direction, EA enforces risk"

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
input int    InpBarsToSend     = 60;                                // Closed bars sent per pair
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
input int    InpEntryStartNY   = 3;                                 // Entries allowed from (NY hour)
input int    InpEntryEndNY     = 12;                                // Entries allowed until (NY hour)
input int    InpFridayFlatNY   = 16;                                // Friday: close all from this NY hour
input int    InpPollSec        = 3;                                 // Command poll interval
input int    InpSlippagePts    = 20;                                // Max slippage in points

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
int OnInit()
{
   if(StringFind(InpURL, "http") != 0) { Print("Set InpURL to your Railway URL (starting with https)"); return INIT_PARAMETERS_INCORRECT; }
   g_pfx = "FXSW_" + IntegerToString(InpMagic) + "_";
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);

   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
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
   if(g_n == 0) { Print("No symbols loaded - check InpSymbols / InpSuffix"); return INIT_FAILED; }

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
   Print("MAXX FX SWARM v1 loaded ", g_n, " pairs, DryRun=", InpDryRun, " lastCmd=", g_lastCmd);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_n; i++) IndicatorRelease(g_atr[i]);
   Comment("");
}

void OnTick() { }

void OnTimer()
{
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

   Comment("MAXX FX SWARM v1  ", (InpDryRun ? "[DRY RUN]" : "[LIVE]"),
           "\nPairs ", g_n, " | Positions ", CountMagicPositions(), "/", InpMaxPositions,
           " | Trades today ", tradesToday, "/", InpMaxTradesDay,
           "\nDay P/L ", DoubleToString(pl, 2), "  (stop -", DoubleToString(InpDayLossUSD, 0), " / +", DoubleToString(InpDayProfitUSD, 0), ")",
           (DayLocked() ? "  LOCKED" : ""),
           "\nEntry window ", (InEntryWindow() ? "OPEN" : "closed"), " | last cmd #", g_lastCmd,
           "\n", g_status);
}
//+------------------------------------------------------------------+
