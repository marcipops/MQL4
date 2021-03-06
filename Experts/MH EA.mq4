//+------------------------------------------------------------------+
//| MH Design from scratch

// Based on: 
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
/*
TODO:
- Ensure stoploss takes into account the spread: difference between Bid & Ask. The spread is added on the Ask side of the trade on MT4.
- Cater for distance in the capital exposure calculations i.e. SL<->OpenPrice
- pp.159 A maximum monthly loss must be no more than 10 percent. If closed trades have resulted in a 10% drawdown to the account in less than a month, stop trading for the balance of the month.
- pp.159 Implement 6% maximum exposure on all open trades.

- Implement https://forum.mql4.com/57285#831181. 
 is NEVER needed. It's a kludge, don't use it. It's use is always wrong. Normallizing Price for pending orders must be a multiple of ticksize, metals are multiple of 0.25 *not a power of ten*.
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

#include <stdlib.mqh>
#include <Dictionary.mqh>
#include <MH_Globals.mqh>
#include <MH_variables.mqh>   // Description of variables
/*
#include <MH_Check.mqh>       // Checking legality of programs used
#include <MH_terminal.mqh>    // Order accounting
#include <MH_inform.mqh>      // Data function
#include <MH_Events.mqh>      // Event tracking function
#include <MH_Trade.mqh>       // Trade function
#include <MH_Open_Ord.mqh>    // Opening one order of the preset type
#include <MH_Close_All.mqh>  // Closing all orders of the preset type
#include <MH_Tral_Stop.mqh>  // StopLoss modification for all orders of the preset type
#include <MH_Lot.mqh>        // Calculation of the amount of lots
*/
#include <MH_Conditions.mqh>  // Stoch conditions
#include <MH_Plot.mqh>        // Plotting functions
#include <MH_MktInfo.mqh>     // Market Information functions
#include <MH_Errors.mqh>      // Error processing function
#include <MH_TradeUnit.mqh>   //TradeUnit Classstate
#include <MH_Position_Size.mqh>   // Position sizing

//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Initialisation
//-----------------------------------------------------------------------------------------------------------------------------------------
int init()
{
   IndicatorBuffers(0);
   Print("WindowBarsPerChart(): ", WindowBarsPerChart());


   ObjGUID = 0; //GUID for name
   TradeUnits.FreeMode(FALSE); //on DeleteObjectByKey(), do NOT delete the object as well as the container in the dictionary

   if (BaseTimeFrame == -1)
      InitPeriods();                   //Set up timeframes for stochastics
   else
      InitPeriodsOpt(BaseTimeFrame);   //used for optimisation only - to find the most profitable base timeframe

//   AccountProperties_Print();        //--- show all the static account information
//   SymbolInfo_Print();
MarketInfo_Print();

   Stoch_Update();                     //Update the MTF Stoch values
//   Level_old=(int)MarketInfo(Symbol(),MODE_STOPLEVEL );//Min. distance
//   Terminal();                         // Order accounting function 

InitStateEvents();
   return(0);
}

//SEMAPHORE
//						
//	
//	int cnt = 0;
//	while(!IsTradeAllowed() && cnt < retry_attempts) 
//	{
//		OrderReliable_SleepRandomTime(sleep_time, sleep_maximum); 
//		cnt++;
//	}


//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Start
//-----------------------------------------------------------------------------------------------------------------------------------------
int start()
{
//   Log("NEW TICK: " + TimeToString(TimeCurrent());
   static datetime LastOpenTime = Time[0];   //time of the open of the last bar - must be static so as to remember the last value between calls to start().
   if (Time[0] > LastOpenTime)   //if new bar
   {//Log(string(__LINE__)+": NEW BAR");
      LastOpenTime = Time[0];          //new bar so save the time of the Open of the current bar
	//if (IsStopped || !IsConnected()) 
	//{
	//   EXIT
	//}
//IMPLEMENT SEMAPHORE CHECK AND SET
 /*
     if(Check()==false)                  // If the usage conditions..
         return (0);                          // ..are not met, then exit
         PlaySound("tick.wav");              // At every tick
      Terminal();                         // Order accounting function 
      Events();                           // Information about events
//      Trade(Criterion());                 // Trade function
      Inform(0);                          // To change the color of objects
*/

      TradeManage();
//IMPLEMENT SEMAPHORE RELEASE      
      MHStoch_PlotAll();  //Plot MTF Stoch Indicator at start of bar only
      FibRet_Plot();
//      FibTimeZone_Plot();
   }
//   if (!MQLInfoInteger(MQL_OPTIMIZATION)) //if not optimizing
//      Indicator_Plot();//called every tick
   return(0);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// EA Deinitialisation
//-----------------------------------------------------------------------------------------------------------------------------------------
int deinit()
{
//   Inform(-1);                         // To delete objects

//TODO: CLOSE ALL ORDERS AND POSITIONS
   TradeUnits_PrintAll();
   LOG("Before TradeUnits.Clear()");
   TradeUnits.Clear(); //release heap
   LOG("After TradeUnits.Clear()");
   TradeUnits_PrintAll();

//**** TODO: NEED TO CLOSE ALL OPEN ORDERS IN DEINIT() *****
//TODO: delete all graph objects
   return(0);
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Process all Trades
//-----------------------------------------------------------------------------------------------------------------------------------------
void TradeManage()
{
   for(TS *node = TradeUnits.GetFirstNode(); node != NULL; node = TradeUnits.GetNextNode())
      node.Manage();

   double TotalCE = Orders_Trading_TotalCE_Calc();   //Calculate Total Capital Exposure across all trades

   switch (EntrySetup())  //Check for entry setup for the *last* bar (once, on the first tick of the bar).  This to wait until the last bar has fully formed before checking entry condition.
   {
//       case SIGNAL_LONG:
//            BuyStop();
//            break;
      case SIGNAL_SHORT:                           //Setup for a short trade
            LOG(": EntryCondition == SIGNAL_SHORT");
            SellStop_TwoUnits_Order(TotalCE);   //Place Sell Stop Pending Order Pair
         break;
   }
}
//-----------------------------------------------------------------------------------------------------------------------------------------
// Print info of all TradeUnit objects in Dictionary TradeUnits
//-----------------------------------------------------------------------------------------------------------------------------------------
void TradeUnits_PrintAll()
{
   int key;
   LOG("Printing all remaining Trades in Dictionary ...");
   TS *node;
   for(node = TradeUnits.GetFirstNode(); node != NULL; node = TradeUnits.GetNextNode())
   {
      TradeUnits.GetCurrentKey(key);
      LOG(StringFormat("OrderTicket(): %d, state: %d", key, node.State));
   }
}


//END OF PROGRAM---------------------------------------------------------------------------------------------------------------------------