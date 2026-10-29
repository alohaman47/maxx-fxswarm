//+------------------------------------------------------------------+
//| MAXX_WATCH_v1.mq5                                                |
//| Read-only watcher for forward-test soldiers (CENTAUR etc).       |
//| Never opens, closes or modifies anything. Every few minutes it   |
//| reads this account's deals/positions for the listed magic        |
//| numbers and posts them to the FX SWARM server dashboard.         |
//| Attach to ANY chart in the same terminal/account as the soldier. |
//+------------------------------------------------------------------+
#property copyright "MAXX"
#property version   "1.00"
#property description "MAXX WATCH v1 - read-only forward-test reporter"

input string   InpURL      = "PASTE-RAILWAY-URL";       // Server base URL, e.g. https + your-app.up.railway.app
input string   InpKey      = "change-me-long-key";       // Must equal MAXX_KEY on Railway
input string   InpSoldiers = "CENTAUR:540001";            // label:magic list, comma separated
input datetime InpStart    = D'2026.09.13 00:00';         // Forward-test start (server time)
input double   InpStartBal = 10000.0;                     // Starting balance of this test account
input int      InpPushMin  = 5;                           // Push every N minutes

string   g_label[];
long     g_magic[];
int      g_n = 0;
datetime g_lastPush = 0;
string   g_status = "";

string Esc(string s)
{
   StringReplace(s, "\\", "/");
   StringReplace(s, "\"", "'");
   return s;
}

string DealsJson(long magic)
{
   string s = "[";
   bool first = true;
   if(!HistorySelect(InpStart, TimeCurrent() + 3600)) return "[]";
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != magic) continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      ENUM_DEAL_TYPE  ty = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
      if(ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL) continue;
      string e = (en == DEAL_ENTRY_IN) ? "in" : ((en == DEAL_ENTRY_OUT || en == DEAL_ENTRY_OUT_BY) ? "out" : "inout");
      if(!first) s += ",";
      first = false;
      s += "{\"t\":" + IntegerToString((long)HistoryDealGetInteger(d, DEAL_TIME)) +
           ",\"pos\":" + IntegerToString((long)HistoryDealGetInteger(d, DEAL_POSITION_ID)) +
           ",\"e\":\"" + e + "\",\"d\":\"" + (ty == DEAL_TYPE_BUY ? "B" : "S") + "\"" +
           ",\"sym\":\"" + Esc(HistoryDealGetString(d, DEAL_SYMBOL)) + "\"" +
           ",\"v\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_VOLUME), 2) +
           ",\"px\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), 5) +
           ",\"pl\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_PROFIT), 2) +
           ",\"sw\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_SWAP), 2) +
           ",\"cm\":" + DoubleToString(HistoryDealGetDouble(d, DEAL_COMMISSION), 2) + "}";
   }
   return s + "]";
}

string OpenJson(long magic, double &floating)
{
   string s = "[";
   bool first = true;
   floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      floating += pl;
      if(!first) s += ",";
      first = false;
      s += "{\"sym\":\"" + Esc(PositionGetString(POSITION_SYMBOL)) + "\"" +
           ",\"d\":\"" + (((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "B" : "S") + "\"" +
           ",\"v\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
           ",\"t\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME)) +
           ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), 5) +
           ",\"pl\":" + DoubleToString(pl, 2) + "}";
   }
   return s + "]";
}

void Push()
{
   string js = "{\"acct\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) +
               ",\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\"" +
               ",\"demo\":" + ((AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO) ? "true" : "false") +
               ",\"now\":" + IntegerToString((long)TimeCurrent()) +
               ",\"start\":" + IntegerToString((long)InpStart) +
               ",\"startBal\":" + DoubleToString(InpStartBal, 2) +
               ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
               ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
               ",\"soldiers\":[";
   for(int k = 0; k < g_n; k++)
   {
      double fl = 0.0;
      string open = OpenJson(g_magic[k], fl);
      if(k > 0) js += ",";
      js += "{\"label\":\"" + Esc(g_label[k]) + "\",\"magic\":" + IntegerToString(g_magic[k]) +
            ",\"floating\":" + DoubleToString(fl, 2) + ",\"open\":" + open + ",\"deals\":" + DealsJson(g_magic[k]) + "}";
   }
   js += "]}";

   char data[];
   char result[];
   string rh;
   StringToCharArray(js, data, 0, StringLen(js), CP_UTF8);
   string headers = "Content-Type: application/json\r\nx-maxx-key: " + InpKey + "\r\n";
   ResetLastError();
   int code = WebRequest("POST", InpURL + "/api/watch", headers, 10000, data, result, rh);
   if(code == -1) g_status = "WebRequest error " + IntegerToString(GetLastError()) + " - add the URL in Tools > Options > Expert Advisors";
   else g_status = "push " + IntegerToString(code) + " " + StringSubstr(CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8), 0, 60);
   Print("WATCH ", g_status);
}

int OnInit()
{
   if(StringFind(InpURL, "http") != 0) { Print("Set InpURL to your Railway URL (starting with https)"); return INIT_PARAMETERS_INCORRECT; }
   string parts[];
   int n = StringSplit(InpSoldiers, ',', parts);
   g_n = 0;
   ArrayResize(g_label, 0);
   ArrayResize(g_magic, 0);
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      int c = StringFind(p, ":");
      if(c <= 0) continue;
      ArrayResize(g_label, g_n + 1);
      ArrayResize(g_magic, g_n + 1);
      g_label[g_n] = StringSubstr(p, 0, c);
      g_magic[g_n] = StringToInteger(StringSubstr(p, c + 1));
      g_n++;
   }
   if(g_n == 0) { Print("InpSoldiers is empty - use label:magic, e.g. CENTAUR:540001"); return INIT_PARAMETERS_INCORRECT; }
   EventSetTimer(30);
   Push();
   g_lastPush = TimeCurrent();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }

void OnTick() { }

void OnTimer()
{
   if(TimeCurrent() - g_lastPush >= InpPushMin * 60)
   {
      g_lastPush = TimeCurrent();
      Push();
   }
   Comment("MAXX WATCH v1 (read-only) | soldiers ", g_n, " | ", g_status);
}
//+------------------------------------------------------------------+
