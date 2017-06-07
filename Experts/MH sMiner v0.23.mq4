//+------------------------------------------------------------------+
//| MH Design from scratch
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#include <stdlib.mqh>
#include <Dictionary.mqh>
#include <Arrays\ArrayObj.mqh>

/*
TODO:
- Ensure stoploss takes into account the spread: difference between Bid & Ask. The spread is added on the Ask side of the trade on MT4.
- Cater for distance in the capital exposure calculations i.e. SL<->OpenPrice
- pp.159 A maximum monthly loss must be no more than 10 percent. If closed trades have resulted in a 10% drawdown to the account in less than a month, stop trading for the balance of the month.
- pp.159 Implement 6% maximum exposure on all open trades.

- Implement https://forum.mql4.com/57285#831181. NormalizeDouble is NEVER needed. It's a kludge, don't use it. It's use is always wrong. Normallizing Price for pending orders must be a multiple of ticksize, metals are multiple of 0.25 *not a power of ten*.
- Include the spread in the slsize calculations?  Because automatically lose the cost of the spread in the trade.
- Change deposit currency from USD to GBP (ask the broker)
- Implement Tr-1BH for ST Unit, at the 61.8% retracement point
- Implement Trade management (LT unit): trail at the 1BL if the S&P reaches a probable Wave-C price target.

- Research wheather 10 bars is the right lookback period for SWING HIGH/LOW calculation.  Prefer something more dynamic and not fixed on an arbitary number i.e. "10". #define LOOKBACK  10      //use 10 period lookback *** NEEDS TO BE VALIDATED ***
- Update PositionSize_Get() to check and do not place trades if the maximum capital exposure on all open trades is above 6 percent. At each bar, total up capital exposure for all open and pending trades i.e. using SL<->OpenPrice
- Going Long - ordering BUY
- decide if modification of trade during the bar, so as to get a better price (if the bid price goes up, then give an opportunity to raise sell stop)?

VERSION HISTORY:
v0.17 Implement Trade management (LT unit): after the second LTF momentum bearish reversal following the HTF momentum reaching the OB zone then Tr-1BH 

NOTES:
Bid is for opening short(sell)/closing long(buy) orders
Ask is for opening long/closing short orders

Orders are usually not finalized instantly, they are always delayed, especially on demo accounts. Usually a few secs, but could take longer.

On an open chart, press F8 and in the common tab you can select "show Ask line". The Ask line is the price you will get when you enter a new long position or when you close an existing short position. 

The spread is added on the Ask side of the trade on MT4, so your stoploss needs to take into account the spread, difference between Bid & Ask.
*/

#undef  _DEBUG
#property strict

#define  TAKEPROFIT  0   //Miner wants to let profits run and take profit by trailing profit stops, not by using Take Profit (TP)
#define  SLIPPAGE    0  //0 as not used for placing pending orders
#define  EXPIRATION  0

#define  SIGNAL_NONE    0
#define  SIGNAL_LONG    1
#define  SIGNAL_SHORT   2

//---------------------------------------------------------------------------
//TODO: PARAMETERS NEED TO BE OPTIMIZED
//Strategy Tester Report - MH sMiner v0.23 - see OneNote
//Pass	Profit	Total trades	Profit factor	Expected Payoff	Drawdown $	Drawdown %
//174	   54660.78	81	            5.65	         674.82	         6134.91	   25.12%	   K=12 	D=13 	slowing=9	OB=75 	OS=25 	SwingHigh=10 	EntryCondS1=49 	RiskRatio=0.03 	RiskRatioTotal=0.06 	BaseTimeFrame=5
extern double OB = 75; //Overbought level
extern double OS = 25; //Oversold level
extern int K = 12;
extern int D = 13;
extern int slowing=9;
extern int SwingHigh=10;      //Lookback period for SwingHigh
extern int EntryCondS1 = 49;
extern double RiskRatio = 0.03;      //3% Maximum capital exposure on any one trade - Miner p.159
extern double RiskRatioTotal = 0.06; //6% Maximum capital exposure on ALL trades - Miner p.159
extern int BaseTimeFrame = -1;  //Base TimeFrame - only use when optimising - to find the most profitable timeframe
//---------------------------------------------------------------------------
int MagicNumber = 12345;  //this EA's unique ID

int period1;  //current timeframe (from current selected chart)
int period2;  //current timeframe + 1
int period3;  //current timeframe + 2
int period4;  //current timeframe + 3
int period5;  //current timeframe + 4

CDictionary TradeUnits();
//-----------------------------------------------------------------------------------------------------------------------------------------
// Trade
//-----------------------------------------------------------------------------------------------------------------------------------------
enum ENUM_TRADE_STATE
{
   STATE0,
   STATE1,
   STATE2,
   STATE3,
   STATE4
};

enum ENUM_TRADE_TYPE
{
   STU,  //Short Term Unit
   LTU   //Long Term Unit
};

class TradeUnit : public CObject
  {
   public: 
//      int   TicketNumber;   //Ticket number
      ENUM_TRADE_TYPE Type;   //Type = ShortTermUnit or LongTermUnit
      ENUM_TRADE_STATE State;   //state
      //--- Default constructor 
//      Trade(int tn, ENUM_TRADE_TYPE tp)
      TradeUnit(ENUM_TRADE_TYPE tp)
      {
//         TicketNumber = tn;
         Type = tp;
         State = STATE0;
      };
  };
//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Initialisation
//-----------------------------------------------------------------------------------------------------------------------------------------
int init()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("TERMINAL_TRADE_ALLOWED = FALSE: Automatic Trading is disabled in the terminal settings (either AutoTrading button or in checkbox Options/Expert Advisors/Allow Automated Trading)");
   else
     {
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
         Alert("MQL_TRADE_ALLOWED = FALSE: Automated trading is disabled in the program settings for ",__FILE__);
     }

   if (BaseTimeFrame == -1)
      InitPeriods();             //Set up the three selected timeframes for stochastics
   else
      InitPeriodsOpt(BaseTimeFrame);   //used for optimisation only - to find the most profitable base timeframe
      
   AccountProperties_Print(); //--- show all the static account information
   SymbolInfo_Print();
   
   return(0);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Deinitialisation
//-----------------------------------------------------------------------------------------------------------------------------------------
int deinit()
{
//TODO: CLOSE ALL ORDERS AND POSITIONS
   TradeUnits_PrintAll();
   Print("Before TradeUnits.Clear()");
   TradeUnits.Clear(); //release heap
   Print("After TradeUnits.Clear()");
   TradeUnits_PrintAll();
   return(0);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Start
//-----------------------------------------------------------------------------------------------------------------------------------------
int start()
{
//   #ifdef _DEBUG Print("NEW TICK: ", TimeCurrent()); #endif 

   static datetime LastOpenTime = Time[0];   //time of the open of the last bar - must be static so as to remember the last value between calls to start().

   if (Time[0] > LastOpenTime)   //if new bar
   {

//#ifdef _DEBUG Print("NEW BAR"); #endif
      LastOpenTime = Time[0];          //new bar so save the time of the Open of the current bar

      Orders_Manage();
   }

   return(0);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Orders_Manage
//-----------------------------------------------------------------------------------------------------------------------------------------
void Orders_Manage()
{
   double TotalCE = 0;              //current risk across all trades
   
   Orders_Trading_Manage();         //Process existing market or pending orders
   Orders_History_Manage();         //Process closed or cancelled orders

   TotalCE = Orders_Trading_TotalCE_Calc();   //Calculate Total Capital Exposure across all trades
   
   switch (EntryCondition())  //Check for entry setup for the *last* bar (once, on the first tick of the bar).  This to wait until the last bar has fully formed before checking entry condition.
   {
//       case SIGNAL_LONG:
//            BuyStop();
//            break;
      case SIGNAL_SHORT:                           //Setup for a short trade
            SellStop_TwoUnits_Order(TotalCE);   //Place Sell Stop Pending Order Pair
         break;
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Process all Opened and Pending Orders from Trading Pool
// Because orderdelete() changes the array of orders in the pool whilst they are being processed, this screws up the iteration in the for-next loop.  Solution: first get all the ordertickets into an array Orders[], and then process each of them.
//-----------------------------------------------------------------------------------------------------------------------------------------
void Orders_Trading_Manage()
{
   int i, j;
   int Orders[];
   int Total = OrdersTotal();  //   #ifdef _DEBUG if (Total > 0) Print("Total live market & pending orders: ", Total); #endif
   ArrayResize(Orders, Total, Total); 
   
   for (i = j = 0; i < Total; i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) == False)
      {
         Print("Error: Line: ", __LINE__, ". ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
         continue;
      }
      if (OrderSymbol() != _Symbol)
      {
         Print("Error: Line: ", __LINE__, ". Invalid symbol - not open in current chart");
         continue;
      }
      if (OrderMagicNumber() != MagicNumber)
      {
         Print("Error: Line: ", __LINE__, ". Trade not for this EA");
         continue ;
      }
      Orders[j++] = OrderTicket();
   }

   for (i = 0; i < j; i++) 
   {
      if (OrderSelect(Orders[i], SELECT_BY_TICKET, MODE_TRADES) == False)
      {
         Print("Error: Line: ", __LINE__, ". ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
         continue;
      }
      Order_Trading_Manage();
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Process an Opened and Pending Order from Trading Pool
//-----------------------------------------------------------------------------------------------------------------------------------------
void Order_Trading_Manage()
{
//      Print("---------------------- Process Next Order from Trading Pool (market and pending) ----------------------");
//      Print("#ticket; OpenTime; TradeOperation; lots; symbol; OpenPrice; StopLoss; TakeProfit; CloseTime; ClosePrice; commission; swap; profit; comment; magic number; pending order expiration date");
//   OrderPrint();           //print out details of the order
   switch(OrderType())
   {
      case OP_SELLSTOP:       //sell stop pending order
         Trade_SellStop_Manage();
         break;
      case OP_SELL:           //sell order
         Trade_Sell_Manage(); //Manage Sell Trade
         break;
      case OP_BUYSTOP:        //buy stop pending order
      case OP_BUY:            //Market Buy order executed from Buy Stop
      case OP_BUYLIMIT:       //buy limit pending order - ERROR
      case OP_SELLLIMIT:      //sell limit pending order - ERROR
      default: //ERROR
         Print("Error: ", __LINE__ , ", Invalid return from OrderType():", OrderType()); 
         break;
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Calculate total capital exposure for all open trades
//-----------------------------------------------------------------------------------------------------------------------------------------
double Orders_Trading_TotalCE_Calc()
{
   int i, Total = OrdersTotal();
   double TCE = 0;   //total CE

   for (i = 0; i < Total; i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) == False)
      {
         Print("Error: Line: ", __LINE__, ". ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
         continue;
      }
      if (OrderSymbol() != _Symbol)
      {
         Print("Error: Line: ", __LINE__, ". Invalid symbol - not open in current chart");
         continue;
      }
      if (OrderMagicNumber() != MagicNumber)
      {
         Print("Error: Line: ", __LINE__, ". Trade not for this EA");
         continue ;
      }

      RefreshRates();            //Get latest trade values

      switch(OrderType())
      {
         case OP_SELLSTOP:       //sell stop pending order
         case OP_SELL:           //sell order
            TCE += (OrderStopLoss() - Bid) * OrderLots();
            break;
         case OP_BUYSTOP:        //buy stop pending order
         case OP_BUY:            //Market Buy order executed from Buy Stop
         case OP_BUYLIMIT:       //buy limit pending order - ERROR
         case OP_SELLLIMIT:      //sell limit pending order - ERROR
         default: //ERROR
            Print("Error: ", __LINE__ , ", Invalid return from OrderType():", OrderType()); 
            break;
      }
   }
   return (TCE);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Manage SellStop Trade
// Following the lower time frame momentum bearish reversal, the Tr-1BL entry strategy continues as long as the momentum remains bearish and does not reach the oversold zone.
// If the momentum makes a bullish reversal or reaches the oversold zone before a Tr-1BL is taken out and the trade executed, the entry is canceled.
//-----------------------------------------------------------------------------------------------------------------------------------------
void Trade_SellStop_Manage()
{
   if (BullishReversalOrOversold())               //STOCH BullishReversal or Oversold on previous bar
   {
      if (TradeUnits.DeleteObjectByKey(OrderTicket()) == NULL) //Delete TradeUnit object
         Print("Program Error: ", "Error: Line: ", __LINE__, ". No Trade object exists for OrderTicket: ", OrderTicket());
      if (OrderDelete(OrderTicket()) == True)   //Cancel Order
         Text_Plot(StringFormat("%dD", OrderTicket()));
      else
         Print("Error: Line: ", __LINE__, ". ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
   }
   else
      SellStop_SingleUnit_Modify();   //Modify Sell Stop Pending Order for one trade unit at Tr-1BL
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Manage Sell Trade
//-----------------------------------------------------------------------------------------------------------------------------------------
void Trade_Sell_Manage()
{
// #ifdef _DEBUG   ShowAccountFinancials(); #endif  //--- show all the information available from the function AccountInfoDouble()
   TradeUnit* tu = TradeUnits.GetObjectByKey(OrderTicket());
   if (tu == NULL)
      Print("Program Error: Line: ", __LINE__, ". No Trade Unit object exists for OrderTicket: ", OrderTicket());
   else if (tu.Type == STU)
      Trade_STU_Sell_Manage(tu);
   else
      Trade_LTU_Sell_Manage(tu);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Manage Short Term Unit of Sell Trade
// p.172 if market reaches the 61.8% retracement OR following the second daily momentum bearish reversal
// then Trail the SL at the 1BL 
//-----------------------------------------------------------------------------------------------------------------------------------------
void Trade_STU_Sell_Manage(TradeUnit* tu)
{
   switch (tu.State)   // Trade state
   {
      case STATE0:  //initial state
         if (LTF_BullishReversal())   //if a Bullish Reversal found
         {
            printf("FIRST BULLISH REVERSAL for OrderTicket(): %d, changing Trade state to 1", OrderTicket());
            Text_Plot(StringFormat("%dS1", OrderTicket()));
            tu.State = STATE1;    //change state to indicate first BullishReversal occurance
         }
         break;
      case STATE1:  //First Bullish Reversal already found, check for the second.  
         if (LTF_BullishReversal())   //if a Bullish Reversal found (pp.172 if the price either reaches the 61.8% retracement or following the second daily momentum (bullish) reversal)
         {//this is the second bullish reversal for this trade.
            printf("SECOND BULLISH REVERSAL found for OrderTicket(): %d, changing Trade state to 2 and start trailing SL @ Tr-1BH on ST-Unit", OrderTicket());
            Text_Plot(StringFormat("%dS2", OrderTicket()));
            SL_Modify_Tr_1BH();   //Start trailing SL @ Tr-1BH on ST unit
            tu.State = STATE2;    //change state to indicate second BullishReversal occurance
         }
         break;
      case STATE2:  //Second Bullish Reversal found and keep trailing SL @ Tr-1BH on ST unit
         Print("Trail SL @ Tr-1BH again for ST-Unit on OrderTicket(): ", OrderTicket());
         SL_Modify_Tr_1BH();   //Trail SL @ Tr-1BH on ST unit
         break;
      default: //ERROR
         Print("Program Error: ", "Error: Line: ", __LINE__, ". Invalid Trade state:", tu.State);
         break;
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Manage Long Term Unit of Sell Trade
// Based on Miner p.180
// IF the second LTF (daily) momentum bullish reversal after the HTF (weekly) momentum reaches the OS zone,
// then trail the stop at the LTF (daily) 1BH
// OR trail the stop at the 1BH if the market reaches a probable Wave-C price target.
//-----------------------------------------------------------------------------------------------------------------------------------------
void Trade_LTU_Sell_Manage(TradeUnit* tu )
{
   switch (tu.State)   // Trade state
   {
      case STATE0:  //initial state, waiting for HTF momentum within OS zone
         if (HTF_Oversold())   //if HTF is Oversold
         {
            printf("HTF is Oversold for OrderTicket(): %d, changing Trade state to 1", OrderTicket());
            Text_Plot(StringFormat("%dL1", OrderTicket()));
            tu.State = STATE1;    //change state to indicate HTF oversold occurance
         }
         break;
      case STATE1:  //HTF oversold, check for the first LTF momentum bullish reversal
         if (LTF_BullishReversal())   //if a LTF bullish Reversal found
         {
            printf("FIRST BULLISH REVERSAL found after HTF OS for OrderTicket(): %d, changing Trade state to 2", OrderTicket());
            Text_Plot(StringFormat("%dL2", OrderTicket()));
            tu.State = STATE2;    //change state to indicate first BullishReversal occurance after HTF is OS
         }
         break;
      case STATE2:  //HTF oversold AND First Bullish Reversal found, check for second Bullish Reversal for LT-Unit and start trailing SL @ Tr-1BH on ST unit
         if (LTF_BullishReversal())   //if Bullish Reversal found
         {
            printf("SECOND BULLISH REVERSAL found after HTF OS for OrderTicket(): %d, start trailing SL @ Tr-1BH on ST-Unit and change Trade state to 3", OrderTicket());
            Text_Plot(StringFormat("%dL3", OrderTicket()));
            SL_Modify_Tr_1BH();   //Trail SL @ Tr-1BH on ST unit
            tu.State = STATE3;    //change state to indicate second BullishReversal occurance after HTF is OS
         }
         break;
      case STATE3:   //HTF oversold AND Second Bullish Reversal found, keep trailing SL @ Tr-1BH on ST unit
            SL_Modify_Tr_1BH();   //Trail SL @ Tr-1BH on ST unit
         break;
      default: //ERROR
         Print("Program Error: ", "Error: Line: ", __LINE__, ". Invalid Trade state:", tu.State);
         break;
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Process Closed or Cancelled Orders from History Pool
//-----------------------------------------------------------------------------------------------------------------------------------------
void Orders_History_Manage()
{
   int Error;
   int Total = OrdersHistoryTotal();

//   #ifdef _DEBUG if (Total > 0) Print("Total closed or cancelled orders: ", Total); #endif

   for (int i = 0; i < Total; i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY) == False)
      {
         Error = True;
         break;
      }
      if (OrderSymbol() != _Symbol)
      {
         Print("Error: ", "Error: Line: ", __LINE__, ". Invalid symbol - not open in current chart");
         break;
      }
      if (OrderMagicNumber() != MagicNumber)
      {
         Print("Error: ", "Error: Line: ", __LINE__, ". Trade not for this EA");
         break;
      }

//      Print("Order selected from history pool (closed and cancelled orders)");
//      OrderPrint();           //print out details of the order

      TradeUnits.DeleteObjectByKey(OrderTicket()); //Delete TradeUnit object (doesn't matter if already deleted)
   }

   if (Error)
      Print("Error: Line: ", __LINE__, ". ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Adjust the target entry price to Tr-1BL (last bar low minus 1 point (tick)
//-----------------------------------------------------------------------------------------------------------------------------------------
//Requirements and Limitations in Making Trades.  https://book.mql4.com/appendix/limits
//StopLevel Minimum Distance Limitation
#define  SELLSTOP_OPENPRICE   ((Bid-OpenPrice) >= StopLevel)   //Bid-OpenPrice ≥ StopLevel
#define  SELLSTOP_SL          ((SL-OpenPrice) >= StopLevel)    //SL-OpenPrice ≥ StopLevel
#define  SELL_SL              ((SL-Ask) >= StopLevel)          //SL-Ask ≥ StopLevel

double SellStop_OpenPrice_Get()
{
   double StopLevel = MarketInfo(_Symbol,MODE_STOPLEVEL) * Point;   //Point is the current symbol point value in the *quote* currency
   double OpenPrice=Low[1]-Point;   /* Miner ... The target entry price is set by Tr-1BL (last bar low minus 1 point (tick) */ #ifdef _DEBUG printf("Wanted SellStop OpenPrice = Low[1]-Point = %.1f-%.1f = %.1f", Low[1], Point, OpenPrice); printf("!((Bid-OpenPrice) >= StopLevel) == !(%.1f-%.1f) = %.1f >= %0.1f == %d", Bid, OpenPrice, Bid-OpenPrice, StopLevel, !SELLSTOP_OPENPRICE); #endif
   if (!SELLSTOP_OPENPRICE)   //if OpenPrice too close
   {
      OpenPrice = Bid - StopLevel;  /* Price set to minimum distance below Bid */ #ifdef _DEBUG printf("Wanted price within StopLevel ... Resetting Wanted price to closest. OpenPrice = Bid - StopLevel = %.1f-%.0f = %.1f", Bid, StopLevel, Bid - StopLevel); #endif
   }
   OpenPrice = NormalizeDouble(OpenPrice, Digits);
   return (OpenPrice);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
//Adjust SellStop SL to the latest before entry (See p.142) ... The initial protective buy-stop was placed one tick above the bar number 3 high (Swing High)
//-----------------------------------------------------------------------------------------------------------------------------------------
double SellStop_SL_Get(double OpenPrice)
{
   double StopLevel = MarketInfo(_Symbol,MODE_STOPLEVEL) * Point;   //Point is the current symbol point value in the *quote* currency
   double SL = CalcSwingHigh() + Point;      /* stop loss level. Requested price of SL: ref Miner, SL = swing high + 1 tick */  #ifdef _DEBUG  printf("Wanted SellStop SL = SwingHigh+Point = %.1f", SL); printf("!((SL-OpenPrice) >= StopLevel) == !(%.1f-%.1f) = %.1f >= %0.1f == %d", SL, OpenPrice, SL-OpenPrice, StopLevel, !SELLSTOP_SL);   #endif
   if (!SELLSTOP_SL)          //if SL too close
   {
      SL = OpenPrice + StopLevel;   #ifdef _DEBUG printf("Wanted SL within StopLevel. Resetting Wanted SL to closest. SL = OpenPrice + StopLevel = %.1f+%.0f = %.1f", OpenPrice, StopLevel, OpenPrice + StopLevel); #endif
   }
   SL = NormalizeDouble(SL, Digits);
   return (SL);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// PLACE PENDING ORDER, TYPE = SELL STOP, FOR BOTH TRADE UNITS
//-----------------------------------------------------------------------------------------------------------------------------------------
#define UNITS  2  //number of units

void SellStop_TwoUnits_Order(double TCE)
{                                                                                                                                            #ifdef _DEBUG   Print("--------------------- Start SellStop_TwoUnits_Order() ---------------------"); #endif
   double OP = SellStop_OpenPrice_Get();
   double SL = SellStop_SL_Get(OP);
   double CE = MathAbs(SL-OP); /* capital exposure for Trade Unit Pair */                                                                    #ifdef _DEBUG     Print"Exposure = MathAbs(OP-SL) = ", CE); #endif
   double Lots = TradeUnit_PositionSize_Get(CE);   /*Miner p.192 Max Position Size = Available Capital x Risk% / Capital Exposure per Unit */#ifdef _DEBUG Print("Lots = TradeUnit_PositionSize_Get(Exposure) = ", Lots); #endif
   Lots = Lots / UNITS;                                  //Divide by 2 to get equal lotsize for STU and LTU
   Lots = Lots_Normalize(Lots);                          /*Ensure Lots is a multiple of allowed Lotsize */                                   #ifdef _DEBUG Print("Lots = Lots_Normalize(Lots): ", PS); #endif
                                                                                                                                             #ifdef _DEBUG Print("Total margin required: ", TULots * MarketInfo(_Symbol,MODE_MARGINREQUIRED), ".  Current Free Margin: ", AccountFreeMargin()); #endif
   if (Lots * UNITS * MarketInfo(_Symbol,MODE_MARGINREQUIRED) > AccountFreeMargin())  /* if margin required to buy Lots is larger than available margin */
      Print("Not enough free margin to cover ", Lots," required lots");
   else
   {
      Print("Line: ", __LINE__, " Total capital exposure: ", TCE, " + (current order CE: ", CE, " * Lots: ", Lots, " * Units: ", UNITS, ") = ", TCE+(CE*Lots*UNITS), ".  Risk limit of 6% AccountEquity: ", RiskRatioTotal * Currency_ConvertDepositToQuote(AccountEquity()), " GBP");
      if (TCE + (CE * Lots * UNITS) >= RiskRatioTotal * Currency_ConvertDepositToQuote(AccountEquity()))        //if total capital exposure over all trades < risk limit
         Print("Line: ", __LINE__, " Total capital exposure: ", TCE, " + (current order CE: ", CE, " * Lots: ", Lots, " * Units: ", UNITS, ") = ", TCE+(CE*Lots*UNITS), ".  Exceeds Risk limit of 6% AccountEquity: ", RiskRatioTotal * Currency_ConvertDepositToQuote(AccountEquity()), " GBP, so rejecting trade");
      else  
      {
         TCE += (CE * Lots * UNITS);   //Add in to total
         Print("Send Sell Stop Order pair (STU and LTU)");
      //         MarketInfo_Print();
      //         AccountPropertiesFinancials_Print();
         SellStop_SingleUnit_Order(STU, Lots, OP, SL);  //Set Sell Stop for Short Term Unit (STU)
//         SellStop_SingleUnit_Order(LTU, Lots, OP, SL);  //Set Sell Stop for Long Term Unit (LTU)
      }
   }
#ifdef _DEBUG   Print("--------------------- End PendingOrder_SellStop_TwoUnits_Order() ---------------------");  #endif
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// PLACE PENDING ORDER, TYPE = SELL STOP, ONE TRADE UNIT
//-----------------------------------------------------------------------------------------------------------------------------------------
void SellStop_SingleUnit_Order(ENUM_TRADE_TYPE type, double lots, double op, double sl)
{
   string comment; color ArrowColor; int ticket;
   
   if (type == STU)
   {
      comment = "MH STU";
      ArrowColor = clrGreen;
   }
   else
   {
      comment = "MH LTU";
      ArrowColor = clrRed;
   }
   if ((ticket = OrderSend(_Symbol, OP_SELLSTOP, lots, op, SLIPPAGE, sl, TAKEPROFIT, comment, MagicNumber, EXPIRATION, ArrowColor)) == -1)
      Print("Error: Line: ", __LINE__,  "OrderSend(): ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
   else
      TradeUnits.AddObject(ticket, new TradeUnit(type));
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// MODIFY PENDING ORDER, TYPE = SELL STOP

// ENTRY STRATEGY - TRAILING ONE BAR ENTRY and STOP (Miner p140)
// P140: Once the conditions are in place for a reversal and following the lower time frame momentum reversal, trail
// the sell-stop to enter the trade one tick above the high of the last completed bar.
// Place the protective stop one tick beyond the swing high or low made prior to entry.
//-----------------------------------------------------------------------------------------------------------------------------------------
void SellStop_SingleUnit_Modify()
{
   double OP = SellStop_OpenPrice_Get();
   double SL = SellStop_SL_Get(OP);
   if (OP > OrderOpenPrice()) //if wanted SellStop.OpenPrice is greater than current SellStop.OpenPrice, then modify the SellStop.OpenPrice upwards (to respect Tr-1BL rule)
   {
      Print("Modifying Sell Stop Order at Tr-1BL");
      if (OrderModify(OrderTicket(), OP, SL, TAKEPROFIT, EXPIRATION, Blue) == False)     //Take profit level is 0 - Miner wants to let profits run and take profit by trailing profit stops
         Print("Error: Line: ", __LINE__, ". ModifySellStop_Tr_1BH(): OrderModify(): ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
   }
   else
   {
#ifdef _DEBUG      Print("Wanted SellStop.OpenPrice <= current OpenPrice, so not modifying Sell Stop Order at Tr-1BL"); #endif
   }         
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// STATE: MARKET ORDER SELL, OPERATION: MODIFY SL ACCORDING TO Tr-1BH. SHORT-TERM UNIT ONLY
//-----------------------------------------------------------------------------------------------------------------------------------------
//Miner p.172 Trade management (short-term unit): Trail the stop at the 1B(H).
void SL_Modify_Tr_1BH()
{
#ifdef _DEBUG   Print("--------------------- Start SL_Modify_Tr_1BH() ---------------------");  #endif
   double StopLevel = MarketInfo(_Symbol,MODE_STOPLEVEL) * Point;
   double SL = High[1] + Point;      //stop loss level. Wanted price of SL: Tr-1BH, SL = last High + 1 point
   #ifdef _DEBUG printf("Wanted Sell SL = Tr_1BH = High[1]+Point = %.1f+%.1f = %.1f", High[1], Point, SL); #endif

#ifdef _DEBUG   printf("!((SL-Ask) >= StopLevel) == !(%.1f-%.1f >= %0.1f == %d", SL, Ask, StopLevel, !SELL_SL); #endif
   if (!SELL_SL)          //if SL too close
   {
      #ifdef _DEBUG printf("Wanted SL within StopLevel. Resetting Wanted SL to closest. SL = Ask + StopLevel = %.1f+%.0f = %.1f", Ask, StopLevel, Ask + StopLevel); #endif
      SL = Ask + StopLevel;
   }

   SL = NormalizeDouble(SL, Digits);

   if (SL < OrderStopLoss()) //if wanted SL is less than current SL, then modify the SL downwards (to respect Tr-1BH rule)
   {
      if (OrderModify(OrderTicket(), OrderOpenPrice(), SL, 0, 0, Blue) == False)//Take profit level is 0 - Miner wants to let profits run and take profit by trailing profit stops
         Print("Error: Line: ", __LINE__, ". SL_Modify_Tr_1BH(): OrderModify(): ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
   }
#ifdef _DEBUG   Print("-------------------- End SL_Modify_Tr_1BH() ---------------------");  #endif
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// CALCULATE SWING HIGH FOR THE LAST n BARS
//-----------------------------------------------------------------------------------------------------------------------------------------
double CalcSwingHigh()
{
   int i, j = 0;
   double Highest = 0;
   double SH;

   for (i = 1; i < SwingHigh; i++)
   {
      if (High[i] > High[i+1] && High[i] > High[i-1]) //if currently selected high is a potential swing high
         if (High[i] > Highest)                       //if hightest potential swing high so far
         {
            Highest = High[i];   //New highest
            j = i;               //New index of highest
         }
   }
    
   if(j > 0)   // swing high found
   {
      SH=High[j]; 
#ifdef _DEBUG      Print("SwingHigh @: ", Time[j], " = ", SH); #endif
   }
   else
      SH=iHighest(NULL,0,MODE_HIGH,SwingHigh);   // swing high not found, so just return the highest value for the range
   return (SH);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// SEND BUY STOP ORDER
//-----------------------------------------------------------------------------------------------------------------------------------------
/*
void BuyStop()
{
         //Check free margin
         if (AccountFreeMargin() < (1000 * Lots)) {
            Print("We have no money. Free Margin = ", AccountFreeMargin());
            return(0);
         }
 
         Ticket = OrderSend(_Symbol, OP_BUYSTOP, Lots, High[1]+1, SLIPPAGE, SL, TP);
         if(Ticket != -1)
         {
            if (OrderSelect(Ticket, SELECT_BY_TICKET, MODE_TRADES))
            {
               Print("BUY order opened : ", OrderOpenPrice());
               Print("[Signal Alert]", "[" + _Symbol + "] " + DoubleToStr(Ask, Digits) + " Open Buy");
   			}
   		}
			else
   		{
            Print("Error opening BUY order: ErrorCode: ", GetLastError(), ", Description: ",ErrorDescription(GetLastError()));
			}
         return(0);
}
*/
//-----------------------------------------------------------------------------------------------------------------------------------------
// DETECT TRADE SETUP FOR LONG OR SHORT
//-----------------------------------------------------------------------------------------------------------------------------------------
int EntryCondition()
{
   int pf = 0; //price field.  0 = Low/High, 1 = Close/Close (default)
//shift to get the stochastic of the last bar (Miner p142: The bar labeled 1 was the bar when the momentum bearish reversal was made.
//*Beginning with the next bar*, a sell-stop one tick below the low of the last completed bar is placed to enter a short trade.)

   double K1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 1);
   double K2 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 0);
   double K3 = iStochastic(NULL, period3, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 0);
   double K4 = iStochastic(NULL, period4, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 0);
//   double K5 = iStochastic(NULL, period5, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 0);

   double D1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 1);
   double D2 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 0);
   double D3 = iStochastic(NULL, period3, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 0);
   double D4 = iStochastic(NULL, period4, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 0);
//   double D5 = iStochastic(NULL, period5, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 0);

   double K1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 2);
   double K2_1 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 1);
   double K3_1 = iStochastic(NULL, period3, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 1);
   double K4_1 = iStochastic(NULL, period4, K, D, slowing, MODE_SMA, pf, MODE_MAIN, 1);

   double D1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 2);
   double D2_1 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 1);
   double D3_1 = iStochastic(NULL, period3, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 1);
   double D4_1 = iStochastic(NULL, period4, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, 1);

//--------------------------------------------------------------------------------------------------------------------------
//Miner Entry Conditions - 3 level MTF
bool K1XO = K1_1<=D1_1 && K1>D1; //K1 Xover
bool K2XO = K2_1<=D2_1 && K2>D2; //K2 Xover
bool K3XO = K3_1<=D3_1 && K3>D3; //K3 Xover
bool K1XU = K1_1>=D1_1 && K1<D1; //K1 Xunder
bool K2XU = K2_1>=D2_1 && K2<D2; //K2 Xunder
bool K3XU = K3_1>=D3_1 && K3<D3; //K3 Xunder

bool L1, L2, S1, S2;
      L1=false;
      L2=false;
      S1=false;
      S2=false;

//Miner p.37 both the fast and slow line must be in the OB or OS zone to consider the indicator OB or OS

         //---------- Long ----------
//Timeframe Period1                             Period2                                                  Period3
         //Bullish reversal AND BELOW OB Zone   Bull AND BELOW OB Zone                                   Bull AND BELOW OB Zone
//L1= K1XO && K1<OB && D1<OB &&              K2>K2_1 && D2>D2_1 && K2<OB && D2<OB &&                  K3>K3_1 && D3>D3_1 && K3<OB && D3<OB;
         //Bullish reversal                     Bear AND INSIDE OS Zone                                  Bear AND INSIDE OS Zone
//L2= K1XO &&                                K2<K2_1 && D2<D2_1 && K2<=OS && D2<=OS &&                K3<K3_1 && D3<D3_1 && K3<=OS && D3<=OS;
      
         //---------- Short ----------
//Timeframe Period1                             Period2                                                  Period3
         //Bearish reversal AND ABOVE OS Zone   Bear and ABOVE OS Zone                                   Bear and ABOVE OS Zone
//S1= K1XU && K1>OS && D1>OS &&              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
         //Bearish reversal                     Bull AND INSIDE OB Zone                                  Bull AND INSIDE OB Zone
//S2= K1XU &&                                K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB &&                K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
//--------------------------------------------------------------------------------------------------------------------------

switch (EntryCondS1)
{
         //Bearish reversal AND ABOVE OS Zone   Bear and ABOVE OS Zone                                   Bear and ABOVE OS Zone
//S1= K1XU && K1>OS && D1>OS &&              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
   case 1:
      S1 = K1XU;
      break;
   case 2:
      S1 = K1XU && K1>OS && D1>OS;
      break;
   case 3:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1;
      break;
   case 4:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1;
      break;
   case 5:
      S1 = K1XU &&                              K2>OS && D2>OS;
      break;
   case 6:
      S1 = K1XU && K1>OS && D1>OS &&            K2>OS && D2>OS;
      break;
   case 7:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS;
      break;
   case 8:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 && K2>OS && D2>OS;
      break;
   case 9:
      S1 = K1XU &&                                                                                       K3<K3_1 && D3<D3_1;
      break;
   case 10:
      S1 = K1XU && K1>OS && D1>OS &&                                                                     K3<K3_1 && D3<D3_1;
      break;
   case 11:
      S1 = K1XU &&                                                                                       K3>OS && D3>OS;
      break;
   case 12:
      S1 = K1XU && K1>OS && D1>OS &&                                                                     K3>OS && D3>OS;
      break;
   case 13:
      S1 = K1XU &&                                                                                       K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 14:
      S1 = K1XU && K1>OS && D1>OS &&                                                                     K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 15:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 &&                                    K3<K3_1 && D3<D3_1;
      break;
   case 16:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 &&                                    K3<K3_1 && D3<D3_1;
      break;
   case 17:
      S1 = K1XU &&                              K2>OS && D2>OS &&                                        K3<K3_1 && D3<D3_1;
      break;
   case 18:
      S1 = K1XU && K1>OS && D1>OS &&            K2>OS && D2>OS &&                                        K3<K3_1 && D3<D3_1;
      break;
   case 19:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1;
      break;
   case 20:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1;
      break;
   case 21:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 &&                                    K3>OS && D3>OS;
      break;
   case 22:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 &&                                    K3>OS && D3>OS;
      break;
   case 23:
      S1 = K1XU &&                              K2>OS && D2>OS &&                                        K3>OS && D3>OS;
      break;
   case 24:
      S1 = K1XU && K1>OS && D1>OS &&            K2>OS && D2>OS &&                                        K3>OS && D3>OS;
      break;
   case 25:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3>OS && D3>OS;
      break;
   case 26:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3>OS && D3>OS;
      break;
   case 27:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 &&                                    K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 28:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 &&                                    K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 29:
      S1 = K1XU &&                              K2>OS && D2>OS &&                                        K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 30:
      S1 = K1XU && K1>OS && D1>OS &&            K2>OS && D2>OS &&                                        K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 31:
      S1 = K1XU &&                              K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
   case 32:
      S1 = K1XU && K1>OS && D1>OS &&            K2<K2_1 && D2<D2_1 && K2>OS && D2>OS &&                  K3<K3_1 && D3<D3_1 && K3>OS && D3>OS;
      break;
         //Bearish reversal                     Bull AND INSIDE OB Zone                                  Bull AND INSIDE OB Zone
//S2= K1XU &&                                K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB &&                K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
   case 33:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1;
      break;
   case 34:
      S1 = K1XU &&                              K2>=OB && D2>=OB ;
      break;
   case 35:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB ;
      break;
   case 36:
      S1 = K1XU &&                                                                                       K3>K3_1 && D3>D3_1;
      break;
   case 37:
      S1 = K1XU &&                                                                                       K3>=OB && D3>=OB;
      break;
   case 38:
      S1 = K1XU &&                                                                                       K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
      break;
   case 39:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 &&                                    K3>K3_1 && D3>D3_1;
      break;
   case 40:
      S1 = K1XU &&                              K2>=OB && D2>=OB &&                                      K3>K3_1 && D3>D3_1;
      break;
   case 41:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB &&                K3>K3_1 && D3>D3_1;
      break;
   case 42:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 &&                                    K3>=OB && D3>=OB;
      break;
   case 43:
      S1 = K1XU &&                              K2>=OB && D2>=OB &&                                      K3>=OB && D3>=OB;
      break;
   case 44:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB &&                K3>=OB && D3>=OB;
      break;
   case 45:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 &&                                    K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
      break;
   case 46:
      S1 = K1XU &&                              K2>=OB && D2>=OB &&                                      K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
      break;
   case 47:
      S1 = K1XU &&                              K2>K2_1 && D2>D2_1 && K2>=OB && D2>=OB &&                K3>K3_1 && D3>D3_1 && K3>=OB && D3>=OB;
      break;

   case 48:
      S1 = K1<D1 && K2<D2 && K3<D3;
      break;
   case 49:
      S1 = (K1_1+K2_1+K3_1+K4_1)/4 >= (D1_1+D2_1+D3_1+D4_1)/4 && (K1+K2+K3+K4)/4 < (D1+D2+D3+D4)/4;
      break;      
}
   
#ifdef _DEBUG
string st;
     if (L1)
         st = "L1";
      else if (S1)

   if (L1 || S1)
      PrintFormat("(%s): [K1_1: %.2f, D1_1: %.2f, K1: %.2f, D1: %.2f] [K2_1: %.2f, D2_1: %.2f, K2: %.2f, D2: %.2f] [K3_1: %.2f, D3_1: %.2f, K3: %.2f, D3: %.2f]", st, K1_1, D1_1, K1, D1, K2_1, D2_1, K2, D2, K3_1, D3_1, K3, D3);
#endif

if (L1)
   return(SIGNAL_LONG);    //Signal Long Condition met
else if (S1)
   return(SIGNAL_SHORT);   //Signal Short condition met
else
   return(SIGNAL_NONE);    //Signal no condition met
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// DETECT IF HIGHER TIMEFRAME STOCH OVERSOLD
//-----------------------------------------------------------------------------------------------------------------------------------------
int HTF_Oversold()
{
   int pf = 0; //price field.  0 = Low/High, 1 = Close/Close (default)
   int s = 1;  //shift to get the stochastic of the previous bar (have to wait for full bar to be formed)
   
   double K2 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s);
   double D2 = iStochastic(NULL, period2, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s);

   bool oversold = K2 <= OS && D2 <= OS;  //Overbought //Miner p.37 both the fast and slow line must be in the OB or OS zone to consider the indicator OB or OS

   if (oversold)
      Print("HTF Oversold detected. K2: ", K2, " D2: ", D2);
   return(oversold);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// DETECT IF LOWEST TIMEFRAME STOCH BULLISH REVERSAL OR OVERSOLD
//-----------------------------------------------------------------------------------------------------------------------------------------
int BullishReversalOrOversold()
{
   int pf = 0; //price field.  0 = Low/High, 1 = Close/Close (default)
   int s = 1;  //shift to get the stochastic of the previous bar (have to wait for full bar to be formed)
   
   double K1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s);
   double D1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s);
   double K1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s+1);
   double D1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s+1);

   bool K1XO = K1_1<=D1_1 && K1>D1;        //K1 Xover
   bool oversold = K1 <= OS && D1 <= OS;  //Oversold //Miner p.37 both the fast and slow line must be in the OB or OS zone to consider the indicator OB or OS

   if (K1XO)
      Print("Bullish Reversal detected");
   if (oversold)
      Print("Oversold detected");
   if (K1XO || oversold)
      Print("K1_1: ", K1_1, ", D1_1: ", D1_1, ", K1: ", K1, " D1: ", D1);
   return(K1XO || oversold);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// DETECT IF LOWEST TIMEFRAME STOCH BULLISH REVERSAL
//-----------------------------------------------------------------------------------------------------------------------------------------
int LTF_BullishReversal()
{
   int pf = 0; //price field.  0 = Low/High, 1 = Close/Close (default)
   int s = 1;  //shift to get the stochastic of the previous bar (have to wait for full bar to be formed)
   
   double K1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s);
   double D1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s);
   double K1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s+1);
   double D1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s+1);

   bool K1XO = K1_1<=D1_1 && K1>D1;        //K1 Xover

   if (K1XO)
      printf("LTF Bullish Reversal detected: K1_1: %0.2f, D1_1: %0.2f, K1: %0.2f, D1: %0.2f", K1_1, D1_1, K1, D1);
   return(K1XO);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// DETECT IF LOWEST TIMEFRAME STOCH BEARISH REVERSAL
//-----------------------------------------------------------------------------------------------------------------------------------------
int LTF_BearishReversal()
{
   int pf = 0; //price field.  0 = Low/High, 1 = Close/Close (default)
   int s = 1;  //shift to get the stochastic of the previous bar (have to wait for full bar to be formed)
   
   double K1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s);
   double D1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s);
   double K1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_MAIN, s+1);
   double D1_1 = iStochastic(NULL, period1, K, D, slowing, MODE_SMA, pf, MODE_SIGNAL, s+1);

   bool K1XU = K1_1>=D1_1 && K1<D1;       //K1 Xunder

   if (K1XU)
      printf("Bearish Reversal detected: K1_1: %0.2f, D1_1: %0.2f, K1: %0.2f, D1: %0.2f", K1_1, D1_1, K1, D1);
   return(K1XU);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// CALCULATE POSITION SIZE OR EXIT IF TOO LARGE FOR ACCOUNT
//-----------------------------------------------------------------------------------------------------------------------------------------
//POSITION SIZING ---------------------------------------------------------------
/* It is unclear from Miner whether to use "account equity" or "account balance", as he uses both phrases interchangeably. whereas with MT4 they are different.
On researching, https://forum.mql4.com/58276/page2#851940 it looks like some people are using "account balance". so that's what I will do until I find out more.
 
Miner p.159: The maximum exposure should be a percentage of the **account equity** available.
If the available equity is $20,000, the maximum capital exposure on a trade should be $600 ($20,000 × 3 percent).
Also the maximum capital exposure on all open trades should be $1,200 ($20,000 × 6 percent).

Maximum position size is a function of maximum initial capital exposure per trade unit.
First, calculate the maximum trade capital exposure of 3% of available **account balance**.
Then calculate the capital exposure *per unit* based on the objective entry price and initial protective stop. (The unit could be a futures contract or per share)
Finally, divide the maximum account capital exposure by the trade unit capital exposure to arrive at the maximum position size for the trade.

Maximum Position Size = Available Capital × 3% / Capital Exposure per Unit
Capital Exposure per Unit = difference between Sell(Buy) Stop and Loss Stop

Definitions:
- Tick: A tick is the smallest change of price.
      In currencies a tick is a Point. Price can change by least significant digit (1.23456 -> 1.23457)
      In metals a Tick is still the smallest change but is larger than a point. If price can change from 123.25 to 123.50, you have a TickSize of 0.25 and a point of 0.01. Pip has no meaning.
- Point: A Point is the least significant digit quoted.
      On a 4 digit broker a point (0.0001) = pip (0.0001). [JPY 0.01 == 0.01]
      On a 5 digit broker a point (0.00001) = 1/10 pip (0.00010/10).
- Pip:
      In currencies a pip is defined as 0.0001 (or for JPY 0.01).
      Just because you quote an extra digit doesn't change the value of a pip. (0.0001 == 0.00010) EA's must adjust pips to points (for mq4).
http://gkfxecn.com/en/trade_specs/traders_calculator.html#t1
1 pip is equal to:
   a change in the fourth digit after the decimal point for currency pairs with five digits after the decimal (0.00010);
   a change in the second digit after the decimal point for currency pairs with three digits after the decimal (0.010);
   a change in the second digit after the decimal point for spot silver XAGUSD (0.010);
   a change in the first digit after the decimal point for spot gold XAUUSD (0,10).

This is why you don't use TickValue by itself. Only as a ratio with TickSize. See DeltaValuePerLot()

MODE_TICKSIZE:       Tick *size* in points
                     MODE_TICKSIZE will usually return the same value as MODE_POINT (or Point for the current symbol).
                     However, an example of where to use MODE_TICKSIZE would be as part of a ratio with MODE_TICKVALUE when performing money management calculations which
                     need to take account of the pair and the account currency. The reason I use this ratio is that although TV and TS may constantly be returned as something like
                     7.00 and 0.00001 respectively. I've seen this (intermittently) change to 14.00 and 0.00002 respectively (just example tick values to illustrate).
MODE_TICKVALUE:      Tick *value* in the *deposit* currency.  This is one-point value in the deposit currency.
MODE_POINT:          Point *size* in the *quote* currency. For the current symbol, it is stored in the predefined variable Point

MODE_MINLOT:         Minimum permitted amount of a lot
MODE_MAXLOT:         Maximum permitted amount of a lot
MODE_LOTSIZE:        contract size in the symbol base currency  e.g. EUR for EURUSD and GBP for GBPJPY. But if your account's currency is USD then the lot size in your account's currency will be different for both EURUSD and GBPJPY and will depend on the related exchange rates even though MODE_LOTSIZE is 10000.
MODE_LOTSTEP:        Step for changing lots (is this the increment value?)

Base currency:       The base currency for CHFJPY is Swiss franc, and the price of one lot will be expressed in Swiss francs.
Deposit currency:    Though it is possible to make trades using various currency pairs, the trading result is always written in only one currency - the deposit currency.
                     If the deposit currency is US dollar, profits and losses will be shown in US dollars, if it is euro, they will be, of course, in euros. 
                     You can get information about your deposit currency using the AccountCurrency() function. It can be used to convert the trade results into deposit currency.
Quote currency:

MODE_MARGINREQUIRED: Free margin required to open 1 lot for buying

Just as lot size must be a multiple of lot step
    double  minLot  = MarketInfo(_Symbol, MODE_MINLOT),
            lotStep = MarketInfo(_Symbol, MODE_LOTSTEP),
    lotSize = MathFloor(lotSize/lotStep)*lotStep;
    if (lotSize < minLot) ...
open price must be a multiple of tick size
    double  tickSize = MarketInfo(_Symbol, MODE_TICKSIZE);
    nowOpen = MathRound(nowOpen/tickSize)*tickSize;
*/
double TradeUnit_PositionSize_Get(double CEQuote) //CEQuote capital exposure *per unit* for UK100 is in quote currency
{
   RefreshRates();                                       // EA  might have been calculating for a long time and needs data refreshing.
   double MaxCEDeposit= AccountEquity() * RiskRatio;     /* Max Capital Exposure for this trade pair in *deposit* currency */ #ifdef _DEBUG   Print("MaxCEDeposit= AccountEquity() * RiskRatio = ", AccountEquity(), " * ", RiskRatio, " = ", MaxCEDepositCurrency); #endif
   double MaxCEQuote = Currency_ConvertDepositToQuote(MaxCEDeposit);   /* convert risk available for this trade pair from deposit to quote currency */ #ifdef _DEBUG Print("MaxCEQuote = RiskAmount / CurrencyAdjuster: ", MaxCEQuoteCurrency, " = ",  RiskAmount, " / ", CurrencyAdjuster); #endif
   double TULots = MaxCEQuote / CEQuote;                 /* lots per Trade Unit */ #ifdef _DEBUG Print("TULots = MaxCEQuote / CEQuote: ", PS, " = ", MaxCEDeposit, " / ", CEQuote); #endif
   
   return (TULots);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Convert deposit to quote currency
//-----------------------------------------------------------------------------------------------------------------------------------------
double Currency_ConvertDepositToQuote(double Deposit)
{
   double CA = 1;                         //Currency adjuster ... default exchange rate = 1.0000.
   if (MarketInfo(_Symbol,MODE_TICKSIZE)!=0)
      CA = MarketInfo(_Symbol,MODE_TICKSIZE) / MarketInfo(_Symbol,MODE_TICKVALUE);
// e.g. deposit currency is USD (like in ETX Demo accounts), quote currency of UK100 is in GBP
// e.g. on 4/6/2016 USDGBP = 0.68884, MODE_TICKSIZE = 0.1, and MODE_TICKVALUE = 0.145172, 
// so with UK100 the value of 1 USD = 0.1 / 0.145172 / = 0.68884 GBP

   return (Deposit*CA);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Normalise Lots to ensure valid number of lots
//-----------------------------------------------------------------------------------------------------------------------------------------
double Lots_Normalize(double LotsRequired)
{
   double LotStep = MarketInfo(_Symbol, MODE_LOTSTEP);

#ifdef _DEBUG Print("Lots required = ", LotsRequired, ".  LotStep = ", LotStep); #endif
   LotsRequired = MathRound(LotsRequired/LotStep) * LotStep;   /* ensure LotsRequired is a multiple of LotsRequiredtep */ #ifdef _DEBUG Print("LotsRequired = MathRound(LotsRequired/LotStep) * LotStep: ", LotsRequired); #endif

//ensure LotsRequired are within min and max allowed
   double MinLot = MarketInfo(_Symbol, MODE_MINLOT);
   double MaxLot = MarketInfo(_Symbol, MODE_MAXLOT);
   if (LotsRequired < MinLot)
   {
      LotsRequired = MinLot;      #ifdef _DEBUG Print("LotsRequired < MinLot, setting LotsRequired to MinLot: ", LotsRequired); #endif
   }
   else if (LotsRequired > MaxLot)
   {
      LotsRequired = MaxLot;      #ifdef _DEBUG Print("LotsRequired > MaxLot, setting LotsRequired to MaxLot: ", LotsRequired); #endif
   }
   return(LotsRequired);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Initialise available timeframes for Stochastic calculations
//-----------------------------------------------------------------------------------------------------------------------------------------
void InitPeriods()
{
   int p[9];
   p[0] = PERIOD_M1;
   p[1] = PERIOD_M5;
   p[2] = PERIOD_M15;
   p[3] = PERIOD_M30;
   p[4] = PERIOD_H1;
   p[5] = PERIOD_H4;
   p[6] = PERIOD_D1;
   p[7] = PERIOD_W1;
   p[8] = PERIOD_MN1;
   

   int i;   //index
   switch (Period())
      {
      case     1 :  i = 0; break;
      case     5 :  i = 1; break;
      case    15 :  i = 2; break;
      case    30 :  i = 3; break;
      case    60 :  i = 4; break;
      case   240 :  i = 5; break;
      case  1440 :  i = 6; break;
      default: // this ea needs current plus 2 higher timeframes to work
         Print("Error: Line: ", __LINE__, ". CANNOT SELECT THIS TIMEFRAME, EXITING PROGRAM");
         TerminalClose(0);     //EXIT PROGRAM!!!
      }

   period1 = p[i];
   period2 = p[i+1];
   period3 = p[i+2];
   printf("InitPeriods(): Timeframes selected: current: %d, current+1: %d, current+2: %d", period1, period2, period3);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Initialise available timeframes for optimization purposes only
//-----------------------------------------------------------------------------------------------------------------------------------------
void InitPeriodsOpt(int SelectedTimeframe)
{
   int p[9];
   p[0] = PERIOD_M1;
   p[1] = PERIOD_M5; //1	2089.67	151	1.10	13.84	7209.88	45.13%	0.00000000	BaseTimeFrame=1	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[2] = PERIOD_M15;//1	379.25	112	1.03	3.39	8959.83	59.84%	0.00000000	BaseTimeFrame=4	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[3] = PERIOD_M30;//1	6444.19	68	   1.52	94.77	6596.77	29.77%	0.00000000	BaseTimeFrame=4	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[4] = PERIOD_H1; //2	3546.43	52	   1.46	68.20	4821.34	27.12%	0.00000000	BaseTimeFrame=4	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[5] = PERIOD_H4; //1	287.64	3	   2.00	95.88	1162.15	10.86%	0.00000000	BaseTimeFrame=0	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[6] = PERIOD_D1; //2	1742.81	4	   6.79	435.70	2049.63	17.22%	0.00000000	BaseTimeFrame=3	OB=80 	OS=20 	K=5 	D=3 	slowing=3 	RiskRatio=0.03 	RiskRatioTotal=0.06
   p[7] = PERIOD_W1;
   p[8] = PERIOD_MN1;
   
   if (SelectedTimeframe > 6)
   {
      Print("Error: Line: ", __LINE__, ". InitPeriodsOpt(): ERROR - CANNOT SELECT THIS TIMEFRAME, EXITING PROGRAM");
      TerminalClose(0);     //EXIT PROGRAM!!!
      return;
   }
   
   period1 = p[SelectedTimeframe];
   period2 = p[SelectedTimeframe+1];
   period3 = p[SelectedTimeframe+2];
   printf("InitPeriodsOpt(): Timeframes selected: current: %d, current+1: %d, current+2: %d", period1, period2, period3);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Print Account Properties: https://docs.mql4.com/constants/environment_state/accountinformation
//-----------------------------------------------------------------------------------------------------------------------------------------
void AccountProperties_Print()
{
   Print("---------------------- Start AccountProperties_Print() ----------------------");
   printf("ACCOUNT_LOGIN: %d",AccountInfoInteger(ACCOUNT_LOGIN)); 

   switch((ENUM_ACCOUNT_TRADE_MODE) AccountInfoInteger(ACCOUNT_TRADE_MODE))          //--- the account type 
     { 
      case(ACCOUNT_TRADE_MODE_DEMO): 
         Print("ACCOUNT_TRADE_MODE: ACCOUNT_TRADE_MODE_DEMO (This is a demo account)"); 
         break; 
      case(ACCOUNT_TRADE_MODE_CONTEST): 
         Print("ACCOUNT_TRADE_MODE: ACCOUNT_TRADE_MODE_CONTEST (This is a competition account)"); 
         break; 
      default:
         Print("ACCOUNT_TRADE_MODE: This is a REAL account, exiting Start()!!"); 
         TerminalClose(0);    //EXIT PROGRAM!!!
         return;              //*** EXIT NOW TO STOP USING A REAL ACCOUNT! **
     } 

   printf("ACCOUNT_LEVERAGE: %d",AccountInfoInteger(ACCOUNT_LEVERAGE)); 
   printf("ACCOUNT_LIMIT_ORDERS (Maximum allowed number of active pending orders) (0-unlimited): %d",AccountInfoInteger(ACCOUNT_LIMIT_ORDERS)); 

   switch((ENUM_ACCOUNT_STOPOUT_MODE)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)) //--- the StopOut level setting mode 
     { 
      case(ACCOUNT_STOPOUT_MODE_PERCENT): 
         Print("ACCOUNT_MARGIN_SO_MODE: ACCOUNT_STOPOUT_MODE_PERCENT (The StopOut level is specified percentage)"); 
         break; 
      case(ACCOUNT_STOPOUT_MODE_MONEY): 
         Print("ACCOUNT_MARGIN_SO_MODE: ACCOUNT_STOPOUT_MODE_MONEY (The StopOut level is specified in monetary terms)"); 
         break; 
     } 

   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) 
      Print("ACCOUNT_TRADE_ALLOWED = TRUE (Trading (manual/automated) for this account is allowed)"); 
   else
   {
      Print("ACCOUNT_TRADE_ALLOWED = FALSE (Trading (manual/automated) for this account is disabled!)");
      Print("AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) may return false in the following cases:");
      Print("(1) No connection to the trade server. That can be checked using TerminalInfoInteger(TERMINAL_CONNECTED)).");
      Print("(2) Trading account switched to read-only mode (sent to the archive).");
      Print("(3) trading on the account is disabled at the trade server side.");
      Print("(4) Cconnection to a trading account has been performed in Investor mode.");
   }

   if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) //Automated trading can be disabled at the trade server side for the current account
      Print("ACCOUNT_TRADE_EXPERT = TRUE (Automated Trading is allowed for any Expert Advisors/scripts for the current account)"); 
   else 
      Print("Automated Trading by Expert Advisors is disabled by the trade server for this account!"); 

//------------------------------------------------------------------------------
// show all the information available from the function AccountInfoString() 
   Print("ACCOUNT_NAME (Client name): ", AccountInfoString(ACCOUNT_NAME)); 
   Print("ACCOUNT_SERVER (The name of the trade server): ", AccountInfoString(ACCOUNT_SERVER)); 
   Print("ACCOUNT_CURRENCY (Deposit currency): ", AccountInfoString(ACCOUNT_CURRENCY)); 
   Print("ACCOUNT_COMPANY (The name of the broker): ", AccountInfoString(ACCOUNT_COMPANY));
    
   Print("---------------------- End AccountProperties_Print() ----------------------");
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Print Account Properties: https://docs.mql4.com/constants/environment_state/accountinformation
//-----------------------------------------------------------------------------------------------------------------------------------------
void AccountPropertiesFinancials_Print()
{
   Print("--------------------- Start AccountPropertiesFinancials_Print() ----------------------");
   printf("ACCOUNT_BALANCE (Account balance in the deposit currency): %G %s",AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_CREDIT (Account credit in the deposit currency): %G %s", AccountInfoDouble(ACCOUNT_CREDIT), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_PROFIT (Current profit of an account in the deposit currency): %G %s", AccountInfoDouble(ACCOUNT_PROFIT), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_EQUITY (Account equity in the deposit currency): %G %s", AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_MARGIN (Account margin used in the deposit currency): %G %s", AccountInfoDouble(ACCOUNT_MARGIN), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_MARGIN_FREE (Free margin of an account in the deposit currency): %G %s",AccountInfoDouble(ACCOUNT_MARGIN_FREE), AccountInfoString(ACCOUNT_CURRENCY)); 
   printf("ACCOUNT_MARGIN_LEVEL (Account margin level): %G%%", AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)); 

   switch((ENUM_ACCOUNT_STOPOUT_MODE)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)) //--- the StopOut level setting mode 
     { 
      case(ACCOUNT_STOPOUT_MODE_PERCENT): 
         printf("ACCOUNT_MARGIN_SO_CALL (Margin call level): %G%%", AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL)); 
         printf("ACCOUNT_MARGIN_SO_SO (Margin stop out level): %G%%", AccountInfoDouble(ACCOUNT_MARGIN_SO_SO)); 
         break; 
      case(ACCOUNT_STOPOUT_MODE_MONEY): 
         printf("ACCOUNT_MARGIN_SO_CALL (Margin call level): %G %s", AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL), AccountInfoString(ACCOUNT_CURRENCY)); 
         printf("ACCOUNT_MARGIN_SO_SO (Margin stop out level): %G %s", AccountInfoDouble(ACCOUNT_MARGIN_SO_SO), AccountInfoString(ACCOUNT_CURRENCY)); 
         break; 
     } 
   Print("---------------------- End AccountPropertiesFinancials_Print() -----------------------");
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// MarketInfo Returns various data about securities listed in the "Market Watch" window
//-----------------------------------------------------------------------------------------------------------------------------------------
void MarketInfo_Print()
{
   Print("---------------------- Start MarketInfo_Print() ----------------------");
   Print("Symbol = ",_Symbol);
   Print("MODE_LOW (Low day price) = ",MarketInfo(_Symbol,MODE_LOW));
   Print("MODE_HIGH (High day price) = ",MarketInfo(_Symbol,MODE_HIGH));
   Print("MODE_TIME (The last incoming tick time) = ",(MarketInfo(_Symbol,MODE_TIME)));
   Print("MODE_BID (Last incoming bid price) = ",MarketInfo(_Symbol,MODE_BID));
   Print("MODE_ASK (Last incoming ask price) = ",MarketInfo(_Symbol,MODE_ASK));
   Print("MODE_POINT (Point size in the quote currency) = ",MarketInfo(_Symbol,MODE_POINT));
   Print("MODE_DIGITS (Digits after decimal point) = ",MarketInfo(_Symbol,MODE_DIGITS));
   Print("MODE_SPREAD (Spread value) = ",MarketInfo(_Symbol,MODE_SPREAD), " points");
   Print("MODE_STOPLEVEL (Stop level) = ",MarketInfo(_Symbol,MODE_STOPLEVEL), " points");
   Print("MODE_LOTSIZE (Lot size in the base currency) = ",MarketInfo(_Symbol,MODE_LOTSIZE), SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE));
   Print("MODE_TICKVALUE (Tick value in the deposit currency) = ",MarketInfo(_Symbol,MODE_TICKVALUE), " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("MODE_TICKSIZE (Tick size) = ",MarketInfo(_Symbol,MODE_TICKSIZE), " points"); 
   Print("MODE_SWAPLONG (Swap of the buy order) = ",MarketInfo(_Symbol,MODE_SWAPLONG));
   Print("MODE_SWAPSHORT (Swap of the sell order) = ",MarketInfo(_Symbol,MODE_SWAPSHORT));
   Print("MODE_STARTING (Market starting date (for futures)) = ",MarketInfo(_Symbol,MODE_STARTING));
   Print("MODE_EXPIRATION (Market expiration date (for futures)) = ",MarketInfo(_Symbol,MODE_EXPIRATION));
   Print("MODE_TRADEALLOWED (Trade is allowed for the symbol) = ",MarketInfo(_Symbol,MODE_TRADEALLOWED));
   Print("MODE_MINLOT (Minimum permitted amount of a lot) = ", MarketInfo(_Symbol,MODE_MINLOT), " lots");
   Print("MODE_LOTSTEP (Step for changing lots) = ",MarketInfo(_Symbol,MODE_LOTSTEP));
   Print("MODE_MAXLOT (Maximum permitted amount of a lot) = ", MarketInfo(_Symbol,MODE_MAXLOT), " lots");
   Print("MODE_SWAPTYPE (Swap calculation method) = ", SwapCalcMethod());
   Print("MODE_PROFITCALCMODE (Profit calculation mode) = ", ProfitCalcMode());
   Print("MODE_MARGINCALCMODE (Margin calculation mode) = ",MarketInfo(_Symbol,MODE_MARGINCALCMODE));
   Print("MODE_MARGININIT (Initial margin requirements for 1 lot) = ",MarketInfo(_Symbol,MODE_MARGININIT));
   Print("MODE_MARGINMAINTENANCE (Margin to maintain open orders calculated for 1 lot) = ",MarketInfo(_Symbol,MODE_MARGINMAINTENANCE));
   Print("MODE_MARGINHEDGED (Hedged margin calculated for 1 lot) = ",MarketInfo(_Symbol,MODE_MARGINHEDGED));
   Print("MODE_MARGINREQUIRED (Free margin required to open 1 lot for buying) = ",MarketInfo(_Symbol,MODE_MARGINREQUIRED), " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("MODE_FREEZELEVEL (Order freeze level) = ", MarketInfo(_Symbol,MODE_FREEZELEVEL), " points"); 
   Print("---------------------- End MarketInfo_Print() ----------------------");
}

string SwapCalcMethod()
{
   string s;
   
   switch((int)MarketInfo(_Symbol,MODE_SWAPTYPE))
   {
      case 0:
         s = "In Points";
         break;
      case 1:
         s = "In the Symbol Base Currency";
         break;
      case 2:
         s = "By Interest";
         break;
      case 3:
         s = "In the Margin Currency";
         break;
   }
   return (s);
}

string ProfitCalcMode()
{
   string s;
   
   switch((int)MarketInfo(_Symbol,MODE_PROFITCALCMODE))
   {
      case 0:
         s = "Forex";
         break;
      case 1:
         s = "CFD";
         break;
      case 2:
         s = "Futures";
         break;
   }
   return (s);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// SymbolInfo prints various data about symbols
//-----------------------------------------------------------------------------------------------------------------------------------------
void SymbolInfo_Print()
{
   Print("SYMBOL_CURRENCY_BASE (Basic currency of a symbol) = ",SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE));
   Print("SYMBOL_CURRENCY_PROFIT (Profit currency) = ",SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT));
   Print("SYMBOL_CURRENCY_MARGIN (Margin currency) = ",SymbolInfoString(_Symbol, SYMBOL_CURRENCY_MARGIN));
   Print("SYMBOL_DESCRIPTION (Symbol description) = ",SymbolInfoString(_Symbol, SYMBOL_DESCRIPTION));
   Print("SYMBOL_PATH (Path in the symbol tree) = ",SymbolInfoString(_Symbol, SYMBOL_PATH));
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// PRINT ERROR DESCRIPTION
//-----------------------------------------------------------------------------------------------------------------------------------------
void Error_Print()
  {
   string error_string;
   int error_code = GetLastError();
   switch(error_code)
     {
      //---- codes returned from trade server
      case 0:
      case 1:   error_string="no error";                                                  break;
      case 2:   error_string="common error";                                              break;
      case 3:   error_string="invalid trade parameters";                                  break;
      case 4:   error_string="trade server is busy";                                      break;
      case 5:   error_string="old version of the client terminal";                        break;
      case 6:   error_string="no connection with trade server";                           break;
      case 7:   error_string="not enough rights";                                         break;
      case 8:   error_string="too frequent requests";                                     break;
      case 9:   error_string="malfunctional trade operation (never returned error)";      break;
      case 64:  error_string="account disabled";                                          break;
      case 65:  error_string="invalid account";                                           break;
      case 128: error_string="trade timeout";                                             break;
      case 129: error_string="invalid price";                                             break;
      case 130: error_string="invalid stops";                                             break;
      case 131: error_string="invalid trade volume";                                      break;
      case 132: error_string="market is closed";                                          break;
      case 133: error_string="trade is disabled";                                         break;
      case 134: error_string="not enough money";                                          break;
      case 135: error_string="price changed";                                             break;
      case 136: error_string="off quotes";                                                break;
      case 137: error_string="broker is busy (never returned error)";                     break;
      case 138: error_string="requote";                                                   break;
      case 139: error_string="order is locked";                                           break;
      case 140: error_string="long positions only allowed";                               break;
      case 141: error_string="too many requests";                                         break;
      case 145: error_string="modification denied because order too close to market";     break;
      case 146: error_string="trade context is busy";                                     break;
      case 147: error_string="expirations are denied by broker";                          break;
      case 148: error_string="amount of open and pending orders has reached the limit";   break;
      case 149: error_string="hedging is prohibited";                                     break;
      case 150: error_string="prohibited by FIFO rules";                                  break;
      //---- mql4 errors
      case 4000: error_string="no error (never generated code)";                          break;
      case 4001: error_string="wrong function pointer";                                   break;
      case 4002: error_string="array index is out of range";                              break;
      case 4003: error_string="no memory for function call stack";                        break;
      case 4004: error_string="recursive stack overflow";                                 break;
      case 4005: error_string="not enough stack for parameter";                           break;
      case 4006: error_string="no memory for parameter string";                           break;
      case 4007: error_string="no memory for temp string";                                break;
      case 4008: error_string="not initialized string";                                   break;
      case 4009: error_string="not initialized string in array";                          break;
      case 4010: error_string="no memory for array\' string";                             break;
      case 4011: error_string="too long string";                                          break;
      case 4012: error_string="remainder from zero divide";                               break;
      case 4013: error_string="zero divide";                                              break;
      case 4014: error_string="unknown command";                                          break;
      case 4015: error_string="wrong jump (never generated error)";                       break;
      case 4016: error_string="not initialized array";                                    break;
      case 4017: error_string="dll calls are not allowed";                                break;
      case 4018: error_string="cannot load library";                                      break;
      case 4019: error_string="cannot call function";                                     break;
      case 4020: error_string="expert function calls are not allowed";                    break;
      case 4021: error_string="not enough memory for temp string returned from function"; break;
      case 4022: error_string="system is busy (never generated error)";                   break;
      case 4050: error_string="invalid function parameters count";                        break;
      case 4051: error_string="invalid function parameter value";                         break;
      case 4052: error_string="string function internal error";                           break;
      case 4053: error_string="some array error";                                         break;
      case 4054: error_string="incorrect series array using";                             break;
      case 4055: error_string="custom indicator error";                                   break;
      case 4056: error_string="arrays are incompatible";                                  break;
      case 4057: error_string="global variables processing error";                        break;
      case 4058: error_string="global variable not found";                                break;
      case 4059: error_string="function is not allowed in testing mode";                  break;
      case 4060: error_string="function is not confirmed";                                break;
      case 4061: error_string="send mail error";                                          break;
      case 4062: error_string="string parameter expected";                                break;
      case 4063: error_string="integer parameter expected";                               break;
      case 4064: error_string="double parameter expected";                                break;
      case 4065: error_string="array as parameter expected";                              break;
      case 4066: error_string="requested history data in update state";                   break;
      case 4099: error_string="end of file";                                              break;
      case 4100: error_string="some file error";                                          break;
      case 4101: error_string="wrong file name";                                          break;
      case 4102: error_string="too many opened files";                                    break;
      case 4103: error_string="cannot open file";                                         break;
      case 4104: error_string="incompatible access to a file";                            break;
      case 4105: error_string="no order selected";                                        break;
      case 4106: error_string="unknown symbol";                                           break;
      case 4107: error_string="invalid price parameter for trade function";               break;
      case 4108: error_string="invalid ticket";                                           break;
      case 4109: error_string="trade is not allowed in the expert properties";            break;
      case 4110: error_string="longs are not allowed in the expert properties";           break;
      case 4111: error_string="shorts are not allowed in the expert properties";          break;
      case 4200: error_string="object is already exist";                                  break;
      case 4201: error_string="unknown object property";                                  break;
      case 4202: error_string="object is not exist";                                      break;
      case 4203: error_string="unknown object type";                                      break;
      case 4204: error_string="no object name";                                           break;
      case 4205: error_string="object coordinates error";                                 break;
      case 4206: error_string="no specified subwindow";                                   break;
      default:   error_string="unknown error";
     }
   Print("ErrorCode: ",error_code, ", Description: ",ErrorDescription(GetLastError()));
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Plot text (s) below bottom of last completed bar
//-----------------------------------------------------------------------------------------------------------------------------------------
void Text_Plot(string s)
{
//      ObjectCreate(TimeToStr(TimeCurrent(),TIME_DATE|TIME_SECONDS), OBJ_ARROW, 0, LastOpenTime, Low[1] - 10);
   string TextObjName = TimeToStr(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   ObjectCreate(TextObjName, OBJ_TEXT, 0, Time[0], Low[0] - 20);
   ObjectSetString(0,TextObjName,OBJPROP_TEXT,s); 
   ObjectSetInteger(0,TextObjName,OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0,TextObjName,OBJPROP_COLOR,clrBlack);  
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Plot Arrow below bottom of last completed bar
//-----------------------------------------------------------------------------------------------------------------------------------------
void Arrow_Plot(bool Buy)
{
//   string TextObjName = "Arrow" + TimeToStr(TimeCurrent(),TIME_DATE|TIME_SECONDS);
//   if (Buy)
//      ObjectCreate(TextObjName,OBJ_ARROW_BUY, 0, LastOpenTime, Low[1] - 30);
//   else
//      ObjectCreate(TextObjName,OBJ_ARROW_SELL, 0, LastOpenTime, Low[1] - 30);

//   ObjectSetString(0,TextObjName,OBJPROP_TEXT,s); 
//   ObjectSetInteger(0,TextObjName,OBJPROP_FONTSIZE, 7);
//   ObjectSetInteger(0,TextObjName,OBJPROP_COLOR,clrBlack);  
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Print info of all TradeUnit objects in Dictionary TradeUnits
//-----------------------------------------------------------------------------------------------------------------------------------------
void TradeUnits_PrintAll()
{
   int key;
   Print("Printing all remaining Trades in Dictionary ...");
   for(TradeUnit* node = TradeUnits.GetFirstNode(); node != NULL; node = TradeUnits.GetNextNode())
   {
      TradeUnits.GetCurrentKey(key);
      printf("OrderTicket(): %d, type: %d, state: %d", key, node.Type, node.State);
   }
}
//END OF PROGRAM---------------------------------------------------------------------------------------------------------------------------