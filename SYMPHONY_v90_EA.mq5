//+------------------------------------------------------------------+
//|                                            SYMPHONY_v90_EA.mq5    |
//|   SYMPHONY Wave Intelligence — MT5 Auto Trader (v90)             |
//|                                                                  |
//|   Port of the fixed-timeframe structure + fractal-stack edge     |
//|   from the SYMPHONY Pine indicator into a self-contained MT5     |
//|   Expert Advisor that trades autonomously on ANY account size    |
//|   via risk-percent position sizing.                              |
//|                                                                  |
//|   ARCHITECTURE (mirrors the indicator):                          |
//|     - 6 FIXED-timeframe structure engines: M1 M3 M5 M15 H1 H4    |
//|       Each derives a structural direction from buffered CHoCH    |
//|       on confirmed swing pivots (timeframe-independent).         |
//|     - Fractal stack: weighted alignment of the 6 layers ->       |
//|       stack direction + 0..100 alignment score (L4>L2>L1>L0..).  |
//|     - Entry: stack aligned >= threshold AND the L0 (M5) primary  |
//|       confirms. Stop = structural M5 swing (ATR fallback).       |
//|       Target = R-multiple of risk. Exit on stack flip.           |
//|     - Optional Ping-Pong mode: always-in, flips on the chosen    |
//|       layer's structure reversal.                                |
//+------------------------------------------------------------------+
#property copyright "SYMPHONY v90"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//================================ INPUTS ===============================
input group "=== Risk & Money Management ==="
input double InpRiskPercent      = 1.0;    // Risk per trade (% of balance)
input double InpTP_R             = 2.0;    // Take profit (R multiple of stop)
input double InpMaxLots          = 0.0;    // Hard lot cap (0 = use broker max)
input double InpMinLots          = 0.0;    // Min lot override (0 = broker min)
input bool   InpUseMoneyStop     = false;  // Also cap risk by fixed money
input double InpMoneyStop        = 0.0;    // Max money risk per trade (0 = off)

input group "=== Structure Engine ==="
input int    InpPivotLen         = 5;      // Pivot length (swing detection)
input double InpChochBufferATR   = 0.75;   // CHoCH buffer (x ATR)
input int    InpAtrLen           = 14;     // ATR length
input int    InpStructBars       = 250;    // Bars analysed per timeframe

input group "=== Entry / Exit Logic ==="
input double InpStackEntryScore  = 70.0;   // Min fractal-stack score to enter (0-100)
input bool   InpRequireL0Confirm = true;   // Require M5 (L0) to match stack dir
input bool   InpExitOnStackFlip  = true;   // Close when stack flips opposite
input double InpStopATRfallback  = 1.5;    // Stop = x ATR if no structural swing
input bool   InpAllowLong        = true;   // Allow longs
input bool   InpAllowShort       = true;   // Allow shorts
input int    InpMaxPositions     = 1;      // Max simultaneous positions (this EA)

input group "=== Ping Pong Mode ==="
input bool   InpPingPong         = false;  // Always-in alternating mode
input int    InpPPSourceTF       = 2;      // PP source layer: 0=M1 1=M3 2=M5 3=M15 4=H1 5=H4

input group "=== Filters & Execution ==="
input int    InpMaxSpreadPoints  = 50;     // Max spread (points) to trade
input int    InpSlippagePoints   = 20;     // Max deviation (points)
input bool   InpTradeNewBarOnly  = true;   // Evaluate once per M5 bar
input ulong  InpMagic            = 90900090;// Magic number
input string InpComment          = "SYMPHONY_v90";

//================================ GLOBALS ==============================
CTrade        trade;
ENUM_TIMEFRAMES TFs[6] = { PERIOD_M1, PERIOD_M3, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4 };
// Layer weights (M1,M3,M5,M15,H1,H4) — higher degrees carry more context.
double        LayerW[6] = { 4.0, 6.0, 14.0, 20.0, 26.0, 30.0 };
int           AtrHandle[6];
datetime      g_lastBarTime = 0;
int           g_pos = 0; // current EA position dir: 1 long, -1 short, 0 flat

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   for(int i=0;i<6;i++)
   {
      AtrHandle[i] = iATR(_Symbol, TFs[i], InpAtrLen);
      if(AtrHandle[i]==INVALID_HANDLE)
      {
         Print("Failed to create ATR handle for TF index ", i);
         return(INIT_FAILED);
      }
   }
   g_pos = CurrentPosDir();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   for(int i=0;i<6;i++)
      if(AtrHandle[i]!=INVALID_HANDLE) IndicatorRelease(AtrHandle[i]);
}

//+------------------------------------------------------------------+
//| ATR value for a layer                                            |
//+------------------------------------------------------------------+
double LayerATR(int idx)
{
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(AtrHandle[idx],0,0,2,buf)<2) return(0.0);
   return(buf[0]>0 ? buf[0] : buf[1]);
}

//+------------------------------------------------------------------+
//| Structural direction for one fixed timeframe                     |
//| Buffered CHoCH on confirmed swing pivots (mirrors f_se in Pine). |
//| Also returns the most recent swing high/low (for stops).         |
//+------------------------------------------------------------------+
int StructureDir(int idx, double &lastSwingHigh, double &lastSwingLow)
{
   ENUM_TIMEFRAMES tf = TFs[idx];
   int pv = InpPivotLen;
   int need = MathMax(InpStructBars, pv*4+10);
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
   if(CopyHigh(_Symbol,tf,0,need,hi) < need)  return(0);
   if(CopyLow (_Symbol,tf,0,need,lo) < need)  return(0);
   if(CopyClose(_Symbol,tf,0,need,cl) < need) return(0);

   double atr = LayerATR(idx);
   if(atr<=0) atr = (hi[0]-lo[0]);
   double buf = atr * InpChochBufferATR;

   double lastSH=0, prevSH=0, lastSL=0, prevSL=0;
   bool   hasSH=false, hasPSH=false, hasSL=false, hasPSL=false;
   int    dir=0;
   lastSwingHigh=0; lastSwingLow=0;

   // Walk oldest -> newest over CONFIRMED bars (need pv bars on each side).
   for(int i=need-1-pv; i>=pv; i--)
   {
      bool isPH=true, isPL=true;
      for(int k=1;k<=pv;k++)
      {
         if(hi[i] < hi[i+k] || hi[i] < hi[i-k]) isPH=false;
         if(lo[i] > lo[i+k] || lo[i] > lo[i-k]) isPL=false;
         if(!isPH && !isPL) break;
      }
      if(isPH){ prevSH=lastSH; hasPSH=hasSH; lastSH=hi[i]; hasSH=true; lastSwingHigh=hi[i]; }
      if(isPL){ prevSL=lastSL; hasPSL=hasSL; lastSL=lo[i]; hasSL=true; lastSwingLow=lo[i]; }

      double c = cl[i];
      if(hasPSH && c > prevSH + buf) dir = 1;   // bullish CHoCH
      if(hasPSL && c < prevSL - buf) dir = -1;  // bearish CHoCH
   }
   return(dir);
}

//+------------------------------------------------------------------+
//| Fractal stack: weighted alignment of all 6 fixed layers          |
//+------------------------------------------------------------------+
void ComputeStack(int &stackDir, double &stackScore, int &l0dir,
                  double &l0SwingHigh, double &l0SwingLow)
{
   double bullW=0, bearW=0, totalW=0;
   l0dir=0; l0SwingHigh=0; l0SwingLow=0;
   for(int i=0;i<6;i++)
   {
      double sh=0, sl=0;
      int d = StructureDir(i, sh, sl);
      totalW += LayerW[i];
      if(d==1)  bullW += LayerW[i];
      if(d==-1) bearW += LayerW[i];
      if(i==2){ l0dir=d; l0SwingHigh=sh; l0SwingLow=sl; }  // L0 = M5
   }
   stackDir   = (bullW>bearW) ? 1 : (bearW>bullW) ? -1 : 0;
   double w   = MathMax(bullW, bearW);
   stackScore = (totalW>0) ? (w/totalW*100.0) : 0.0;
}

//+------------------------------------------------------------------+
//| Ping-pong layer direction                                        |
//+------------------------------------------------------------------+
int PingPongDir()
{
   int idx = (InpPPSourceTF>=0 && InpPPSourceTF<6) ? InpPPSourceTF : 2;
   double sh=0, sl=0;
   return StructureDir(idx, sh, sl);
}

//+------------------------------------------------------------------+
//| Risk-based lot sizing — works on ANY account size                |
//+------------------------------------------------------------------+
double LotsForRisk(double stopDistancePrice)
{
   if(stopDistancePrice<=0) return(0.0);
   double bal       = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPercent / 100.0;
   if(InpUseMoneyStop && InpMoneyStop>0)
      riskMoney = MathMin(riskMoney, InpMoneyStop);

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0) return(0.0);

   double lossPerLot = (stopDistancePrice / tickSize) * tickVal;
   if(lossPerLot<=0) return(0.0);

   double lots = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpMinLots>0) minLot = MathMax(minLot, InpMinLots);
   if(InpMaxLots>0) maxLot = MathMin(maxLot, InpMaxLots);
   if(step<=0) step = minLot>0 ? minLot : 0.01;

   lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
//| Current EA position direction (by magic & symbol)                |
//+------------------------------------------------------------------+
int CurrentPosDir()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      return (type==POSITION_TYPE_BUY) ? 1 : -1;
   }
   return(0);
}

int CountPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)==(long)InpMagic) n++;
   }
   return(n);
}

void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      trade.PositionClose(tk);
   }
}

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Open a trade with risk sizing                                    |
//+------------------------------------------------------------------+
void OpenTrade(int dir, double stopPrice)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (dir==1) ? ask : bid;
   double stopDist = MathAbs(entry - stopPrice);
   if(stopDist <= _Point*2) return;

   double lots = LotsForRisk(stopDist);
   if(lots<=0){ Print("Lot size 0 — risk too small or invalid tick data"); return; }

   double tp = (dir==1) ? entry + stopDist*InpTP_R : entry - stopDist*InpTP_R;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(stopPrice, digits);
   tp        = NormalizeDouble(tp, digits);

   bool ok = (dir==1) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment)
                      : trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);
   if(ok) g_pos = dir;
   else   Print("Order failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Main                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // New-bar gate (evaluate once per M5 bar) for stability.
   if(InpTradeNewBarOnly)
   {
      datetime bt = iTime(_Symbol, PERIOD_M5, 0);
      if(bt==g_lastBarTime) return;
      g_lastBarTime = bt;
   }

   g_pos = CurrentPosDir();

   //============================ PING PONG ============================
   if(InpPingPong)
   {
      int pp = PingPongDir();
      if(pp!=0 && pp!=g_pos)
      {
         if(!SpreadOK()) return;
         if(g_pos!=0) CloseAll();
         // structural stop from the source layer
         double sh=0, sl=0;
         StructureDir((InpPPSourceTF>=0&&InpPPSourceTF<6)?InpPPSourceTF:2, sh, sl);
         double atr = LayerATR(2);
         double price = (pp==1)? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double stop  = (pp==1) ? ((sl>0 && sl<price)? sl : price-atr*InpStopATRfallback)
                                : ((sh>0 && sh>price)? sh : price+atr*InpStopATRfallback);
         if((pp==1 && InpAllowLong) || (pp==-1 && InpAllowShort))
            OpenTrade(pp, stop);
      }
      return;
   }

   //============================ STACK MODE ===========================
   int    stackDir=0, l0dir=0;
   double stackScore=0, l0SH=0, l0SL=0;
   ComputeStack(stackDir, stackScore, l0dir, l0SH, l0SL);

   // Exit on opposing stack flip
   if(g_pos!=0 && InpExitOnStackFlip && stackDir!=0 && stackDir!=g_pos)
   {
      CloseAll();
      g_pos = 0;
   }

   // Entry conditions
   bool wantLong  = (stackDir==1)  && InpAllowLong;
   bool wantShort = (stackDir==-1) && InpAllowShort;
   bool scoreOK   = (stackScore >= InpStackEntryScore);
   bool l0OK      = (!InpRequireL0Confirm) || (l0dir==stackDir);

   if(scoreOK && l0OK && CountPositions() < InpMaxPositions && g_pos==0 && SpreadOK())
   {
      double atr = LayerATR(2); // M5 atr
      if(wantLong)
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double stop  = (l0SL>0 && l0SL<price) ? l0SL : price - atr*InpStopATRfallback;
         OpenTrade(1, stop);
      }
      else if(wantShort)
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double stop  = (l0SH>0 && l0SH>price) ? l0SH : price + atr*InpStopATRfallback;
         OpenTrade(-1, stop);
      }
   }
}
//+------------------------------------------------------------------+
