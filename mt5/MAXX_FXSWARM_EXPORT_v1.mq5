//+------------------------------------------------------------------+
//| MAXX_FXSWARM_EXPORT_v1.mq5  (SCRIPT - drag onto any chart once)  |
//| Exports M15 history of the 25 FX SWARM pairs to CSV for the      |
//| technique-lab backtest. Output: MQL5\Files\FXSWARM\<PAIR>.csv    |
//| Format: #meta,PAIR,digits,point  then  time,open,high,low,close, |
//|         spread   (time = epoch seconds, server clock)            |
//+------------------------------------------------------------------+
#property copyright "MAXX"
#property version   "1.00"
#property script_show_inputs

input string   InpSymbols = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,EURGBP,EURJPY,GBPJPY,AUDJPY,EURAUD,EURCHF,GBPCHF,CADJPY,CHFJPY,NZDJPY,AUDCAD,AUDNZD,GBPAUD,GBPCAD,EURCAD,EURNZD,GBPNZD,AUDCHF";
input string   InpSuffix  = "";                      // Broker symbol suffix, e.g. ".a"
input datetime InpFrom    = D'2024.01.01 00:00';     // Export from this date
input ENUM_TIMEFRAMES InpTF = PERIOD_M15;            // Timeframe

bool ExportOne(string base)
{
   string sym = base + InpSuffix;
   if(!SymbolSelect(sym, true)) { Print("Symbol not found: ", sym); return false; }

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = 0;
   // history may need a few tries to download from the server
   for(int attempt = 0; attempt < 10; attempt++)
   {
      got = CopyRates(sym, InpTF, InpFrom, TimeCurrent(), r);
      if(got > 0) break;
      Sleep(1500);
   }
   if(got <= 0) { Print("No data for ", sym, " err ", GetLastError()); return false; }

   string fname = "FXSWARM\\" + base + ".csv";
   int fh = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { Print("Cannot open ", fname, " err ", GetLastError()); return false; }

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   FileWriteString(fh, "#meta," + base + "," + IntegerToString(digits) + "," + DoubleToString(point, digits) + "\n");
   FileWriteString(fh, "time,open,high,low,close,spread\n");
   for(int i = 0; i < got; i++)
   {
      FileWriteString(fh, IntegerToString((long)r[i].time) + "," +
                          DoubleToString(r[i].open, digits) + "," +
                          DoubleToString(r[i].high, digits) + "," +
                          DoubleToString(r[i].low, digits) + "," +
                          DoubleToString(r[i].close, digits) + "," +
                          IntegerToString(r[i].spread) + "\n");
   }
   FileClose(fh);
   Print(base, ": ", got, " bars from ", TimeToString(r[0].time), " to ", TimeToString(r[got - 1].time));
   return true;
}

void OnStart()
{
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   int ok = 0;
   for(int i = 0; i < n; i++)
   {
      string b = parts[i];
      StringTrimLeft(b);
      StringTrimRight(b);
      StringToUpper(b);
      if(StringLen(b) < 6) continue;
      if(ExportOne(b)) ok++;
   }
   string msg = "FXSWARM export done: " + IntegerToString(ok) + "/" + IntegerToString(n) +
                " pairs -> " + TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\FXSWARM";
   Print(msg);
   Alert(msg);
}
//+------------------------------------------------------------------+
