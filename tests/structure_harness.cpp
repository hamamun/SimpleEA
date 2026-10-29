// Test harness for production MQL function bodies extracted by
// test_structure_plan.py. This is C++ with broker/terminal stubs, NOT a
// substitute for compiling or testing in MetaTrader.
#include <algorithm>
#include <cmath>
#include <cfloat>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <set>
#include <vector>

using string = std::string;
using datetime = long long;
using ulong = unsigned long;
#define MathMax(a,b) std::fmax((a),(b))
#define MathMin(a,b) std::fmin((a),(b))
#define MathAbs(a) std::fabs(a)
#define MathFloor(a) std::floor(a)
#define MathCeil(a) std::ceil(a)
#define MathLog(a) std::log(a)
#define MathSqrt(a) std::sqrt(a)
double MathRound(double x) { return std::round(x); }
double NormalizeDouble(double x, int n) { double f=std::pow(10.0,n); return std::round(x*f)/f; }
double NormPrice(double x) { return NormalizeDouble(x, 2); }
template<class T> int ArraySize(const std::vector<T> &a) { return static_cast<int>(a.size()); }
template<class T> void ArrayResize(std::vector<T> &a, int n) { a.resize(n); }
template<class T, size_t N> int ArraySize(const T (&)[N]) { return static_cast<int>(N); }
template<class... A> void PrintFormat(const char*, A...) {}

#define STRUCTURE_M5 36
#define STRUCTURE_M15 48
#define STRUCTURE_M30 72
#define OBS_HORIZON_M5 4
#define OBS_HORIZON_M15 6
#define OBS_HORIZON_M30 8
#define RANGE_BARS 20
#define SYMBOL_VOLUME_MIN 1
#define SYMBOL_VOLUME_MAX 2
#define SYMBOL_VOLUME_STEP 3
#define POSITION_VOLUME 4
#define ORDER_POSITION_ID 5
#define ORDER_SYMBOL 6
#define ORDER_MAGIC 7
#define ORDER_STATE 8
#define TERMINAL_CONNECTED 9
#define DEAL_POSITION_ID 10
#define DEAL_ENTRY 11
#define DEAL_VOLUME 12
#define DEAL_ENTRY_IN 0
#define DEAL_ENTRY_OUT 1
#define DEAL_ENTRY_OUT_BY 2
#define DEAL_ENTRY_INOUT 3
#define ORDER_STATE_CANCELED 4
#define ORDER_STATE_EXPIRED 5
#define ORDER_STATE_REJECTED 6
#define ORDER_STATE_FILLED 7
#define ORDER_STATE_PLACED 8
#define ORDER_TYPE 13
#define ORDER_TYPE_BUY 1
#define ORDER_TYPE_SELL 2
#define ORDER_TYPE_BUY_LIMIT 3
#define ORDER_TYPE_SELL_LIMIT 4
#define ORDER_TYPE_BUY_STOP 5
#define ORDER_TYPE_SELL_STOP 6
#define ORDER_TYPE_BUY_STOP_LIMIT 7
#define ORDER_TYPE_SELL_STOP_LIMIT 8
#define SYMBOL_POINT 14
#define ORDER_TYPE_TIME 15
#define ORDER_TIME_EXPIRATION 16
#define ORDER_PRICE_STOPLIMIT 17
#define ORDER_PRICE_OPEN 18
#define ORDER_SL 19
#define ORDER_TP 20
#define TRADE_ACTION_MODIFY 21
#define TRADE_RETCODE_DONE 10009
#define TRADE_RETCODE_PLACED 10008
#define TRADE_RETCODE_NO_CHANGES 10025
#define TRADE_RETCODE_REJECT 10006
#define ZeroMemory(a) ((a) = {})
using ENUM_ORDER_TYPE = int;
using ENUM_ORDER_TYPE_TIME = int;

struct MqlRates { double open=0, high=0, low=0, close=0; int spread=0; long tick_volume=0; };
struct SStructureGeometry { double entry=0,stop=0,cap[3]={},nearBarrier=0; int issue=0; };
struct SAutoState {
    bool active=false, isOpen=false;
    ulong ticket=0, diaryPositionId=0;
    int dir=1, entryScore=0;
    double initLot=0, curLot=0, entryPrice=0, slPrice=0, tpPrice=0, tp1Price=0, tp2Price=0;
    int slPts=0,tp1Pts=0,tp2Pts=0,tp3Pts=0;
    bool modernTargets=false, legacyRecovery=false, newTradeMarker=false, legacyTradeMarker=false;
    bool tp1Hit=false,tp2Hit=false,tp1Skipped=false,tp2Skipped=false,tp1Short=false,tp2Short=false,cancelPending=false;
    double tp1StartLot=0,tp1GoalLot=0,tp1DoneLot=0,tp2StartLot=0,tp2GoalLot=0,tp2DoneLot=0;
    bool tp1Awaiting=false,tp2Awaiting=false,isRange=false;
    double rngTop=0,rngBot=0;
    datetime placedBar=0;
    long diaryRecordId=0,diaryPlacedDayKey=0;
    int diaryPlanSlPts=0,diaryRegime=0,diaryStyle=0;
    datetime diaryPlacedAt=0,diaryLocalPlaced=0;
    double diaryCostTp1Pct=0,diaryPeakTp1Pct=0;
} g_auto[3];
struct Row { string tag="M5"; } g_rows[3];

string _Symbol="TEST";
double minimumLot=.01, maximumLot=100.0, volumeStep=.01;
double SymbolInfoDouble(const string&, int field) {
    return field==SYMBOL_VOLUME_MIN ? minimumLot : field==SYMBOL_VOLUME_MAX ? maximumLot : volumeStep;
}
long MagicForTF(int i) { return 100+i; }
string AutoGVKey(int i, string field) { return std::to_string(i)+":"+field; }
std::map<string,double> globals;
bool failGlobal=false;
std::set<string> failKeys;
datetime GlobalVariableSet(string k, double v) { if(failGlobal || failKeys.count(k)) return 0; globals[k]=v; return 1; }
bool GlobalVariableCheck(string k) { return globals.count(k)>0; }
double GlobalVariableGet(string k) { auto it=globals.find(k); return it==globals.end()?0:it->second; }
bool GlobalVariableDel(string k) { return globals.erase(k)>0; }
void GlobalVariablesFlush() {}
std::map<ulong,ulong> orderPosition;
std::map<ulong,long> orderStates;
struct Deal { ulong id,position; long entry; double volume; };
std::vector<Deal> historyDeals;
bool connected=true, historyAvailable=true;
ulong selectedHistoryPosition=0;
bool TerminalInfoInteger(int) { return connected; }
bool HistoryOrderSelect(ulong ticket) { return historyAvailable && (orderPosition.count(ticket)>0 || orderStates.count(ticket)>0); }
long long HistoryOrderGetInteger(ulong ticket, int field) {
    return field==ORDER_STATE ? orderStates[ticket] : static_cast<long long>(orderPosition[ticket]);
}
bool HistorySelectByPosition(ulong pos) { selectedHistoryPosition=pos; return historyAvailable; }
int HistoryDealsTotal() { return static_cast<int>(historyDeals.size()); }
ulong HistoryDealGetTicket(int k) { return historyDeals[k].id; }
long long HistoryDealGetInteger(ulong id, int field) {
    for(auto &d:historyDeals)if(d.id==id)return field==DEAL_ENTRY?d.entry:static_cast<long long>(d.position);
    return 0;
}
double HistoryDealGetDouble(ulong id, int) { for(auto &d:historyDeals)if(d.id==id)return d.volume;return 0; }
bool LegacyDiaryTargetPrices(int, double, double&, double&) { return false; }

struct BrokerOrder { ulong ticket; long magic; string symbol; int type; double price=0,sl=0,tp=0; };
std::vector<BrokerOrder> liveOrders;
int selectedOrder=-1, deleteCalls=0;
bool deleteAccepted=false, tradingAllowed=true;
ulong clockMs=3000, g_lastResidualCancelMs[3]={};
ulong GetTickCount64() { return clockMs; }
bool CanTradeNow() { return tradingAllowed; }
int OrdersTotal() { return static_cast<int>(liveOrders.size()); }
ulong OrderGetTicket(int k) { selectedOrder=k; return liveOrders[k].ticket; }
string OrderGetString(int) { return liveOrders[selectedOrder].symbol; }
long OrderGetInteger(int field) {
    return field==ORDER_TYPE ? liveOrders[selectedOrder].type : field==ORDER_MAGIC ? liveOrders[selectedOrder].magic : 0;
}
bool OrderSelect(ulong ticket) {
    for(int k=0;k<(int)liveOrders.size();k++)if(liveOrders[k].ticket==ticket){selectedOrder=k;return true;}
    return false;
}
double OrderGetDouble(int field) {
    auto &o=liveOrders[selectedOrder];return field==ORDER_PRICE_OPEN?o.price:field==ORDER_SL?o.sl:field==ORDER_TP?o.tp:0;
}
struct MqlTradeRequest { int action=0; ulong order=0; string symbol; double price=0,sl=0,tp=0,stoplimit=0; ENUM_ORDER_TYPE_TIME type_time=0; datetime expiration=0; };
struct MqlTradeResult { unsigned int retcode=0; };
unsigned int modifyRetcode=TRADE_RETCODE_REJECT;
bool modifySent=true, modifyVisible=false;
bool OrderSend(MqlTradeRequest &req, MqlTradeResult &res) {
    res.retcode=modifyRetcode;
    if(modifyVisible && OrderSelect(req.order)) {auto &o=liveOrders[selectedOrder];o.price=req.price;o.sl=req.sl;o.tp=req.tp;}
    return modifySent;
}
void NoteMarketClosedRetcode(unsigned int) {}
bool TradeDeleteOrder(ulong ticket) {
    ++deleteCalls;
    if(!deleteAccepted) return false;
    liveOrders.erase(std::remove_if(liveOrders.begin(),liveOrders.end(),[&](auto &o){return o.ticket==ticket;}),liveOrders.end());
    return true;
}

struct Response { int status; double volume; bool uncertain; bool update; };
std::vector<Response> responses;
int closeCalls=0;
double brokerVolume=0;
bool positionExists=true;
bool PositionSelectByTicket(ulong) { return positionExists; }
double PositionGetDouble(int) { return brokerVolume; }
int TradeClosePosition(ulong, int, double requested, long, double &executed, bool &uncertain) {
    ++closeCalls;
    if(responses.empty()) { std::fprintf(stderr,"unexpected close request\n"); std::exit(2); }
    Response r=responses.front(); responses.erase(responses.begin());
    if(r.volume > requested + 1e-7) { std::fprintf(stderr,"over-requested mock execution\n"); std::exit(2); }
    executed=r.volume; uncertain=r.uncertain;
    if(r.status==1 && r.update) brokerVolume=NormalizeDouble(brokerVolume-r.volume,8);
    return r.status;
}

#include "extracted.hpp"

void check(bool ok, const char *message) { if(!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); } }
bool eq(double a, double b) { return std::fabs(a-b)<1e-7; }
MqlRates bar(double o,double h,double l,int spread=0) { MqlRates b; b.open=o;b.high=h;b.low=l;b.close=o;b.spread=spread;return b; }
void reset() { globals.clear();orderPosition.clear();orderStates.clear();historyDeals.clear();connected=true;historyAvailable=true;responses.clear();liveOrders.clear();failKeys.clear();closeCalls=0;deleteCalls=0;failGlobal=false;deleteAccepted=false;tradingAllowed=true;modifyRetcode=TRADE_RETCODE_REJECT;modifySent=true;modifyVisible=false;clockMs=3000;for(auto &x:g_lastResidualCancelMs)x=0;brokerVolume=0;positionExists=true;minimumLot=.01;maximumLot=100;volumeStep=.01;for(auto &a:g_auto)a=SAutoState{}; }
void broker_slot(ulong ticket, bool open, ulong pos, double entry, double sl, double tp) {
    auto &a=g_auto[0]; a=SAutoState{};a.active=true;a.ticket=ticket;a.isOpen=open;a.diaryPositionId=pos;
    a.dir=1;a.curLot=1;a.initLot=1;a.entryPrice=entry;a.slPrice=sl;a.tpPrice=tp;
}
void save_new_pending(ulong ticket=42) {
    broker_slot(ticket,false,0,100,99,103);
    auto &a=g_auto[0];a.tp1Price=101;a.tp2Price=102;a.modernTargets=true;
    check(SaveAutoSlotState(0),"persist new pending");
}

void test_geometry() {
    std::vector<MqlRates> b;
    double lows[]={100,101,99,101,100,102,101,103,102,104,103,104};
    double highs[]={101,102,101,103,102,104,103,105,104,106,105,107};
    for(int k=0;k<12;k++) b.push_back(bar((highs[k]+lows[k])/2,highs[k],lows[k]));
    check(ConfirmedSwingHigh(b,9,11) && !ConfirmedSwingHigh(b,9,9),
          "opposing swing needs its closed confirmation bar");
    b[9].high=108;
    SStructureGeometry buy{};
    check(StructureGeometry(b,11,0,1,true,false,105,105.05,.01,.01,.02,buy),"buy geometry");
    check(eq(buy.entry,105.05)&&eq(buy.stop,102.95)&&eq(buy.cap[0],2.95),"buy confirmed target structure");
    SStructureGeometry bad{};
    check(!StructureGeometry(b,11,0,1,true,false,105,105.05,.01,0,.02,bad) && bad.issue==STRUCTURE_INPUT, "invalid structure input is identified");
    check(!StructureGeometry(b,11,0,1,true,false,90,90.05,.01,.01,.02,bad) && bad.issue==STRUCTURE_NO_STOP, "missing stop swing is identified");
    check(!StructureGeometry(b,11,0,1,false,false,90,90.05,.01,.01,.02,bad) && bad.issue==STRUCTURE_NO_ENTRY, "missing limit swing is identified");
    check(!StructureGeometry(b,11,0,1,false,true,90,90.05,.01,.01,.02,bad) && bad.issue==STRUCTURE_ENTRY_DISTANCE, "range limit broker distance is identified");
    check(!StructureGeometry(b,11,0,1,true,false,105,105.05,.01,.01,5,bad) && bad.issue==STRUCTURE_STOP_DISTANCE, "market stop broker distance is identified");
    SStructureGeometry pending{};
    check(StructureGeometry(b,11,0,1,false,false,105,105.05,.01,.01,.02,pending),"buy limit geometry");
    check(eq(pending.entry,103)&&eq(pending.stop,101.95),"limit stop is beyond a separate pivot");
    b.push_back(bar(1,999,0));
    SStructureGeometry future{};
    check(StructureGeometry(b,11,0,1,true,false,105,105.05,.01,.01,.02,future),"future-independent geometry");
    check(eq(future.entry,buy.entry)&&eq(future.stop,buy.stop)&&eq(future.cap[0],buy.cap[0]),"no lookahead in pivots");
    std::vector<MqlRates> mirrored;
    for(int k=0;k<12;k++) mirrored.push_back(bar(210-b[k].open,210-b[k].low,210-b[k].high));
    SStructureGeometry sell{};
    check(StructureGeometry(mirrored,11,0,-1,true,false,104.95,105,.01,.01,.02,sell),"sell geometry");
    check(eq(sell.entry,210-buy.entry)&&eq(sell.stop,210-buy.stop),"sell entry and stop mirror buy");
    check(eq(sell.cap[0],buy.cap[0]-.05),"sell target cap converts Bid support to Ask using spread");
    SStructureGeometry sellNear{};
    check(StructureGeometry(mirrored,11,0,-1,true,false,102.02,102.07,.01,.01,.02,sellNear),"sell near-barrier geometry");
    check(eq(sellNear.nearBarrier,102.05),"SELL confirmed support inside spread is not silently discarded");
    SStructureGeometry buyNear{};
    check(StructureGeometry(b,11,0,1,true,false,107.98,108.03,.01,.01,.02,buyNear),"buy near-barrier geometry");
    check(eq(buyNear.nearBarrier,108),"BUY confirmed resistance inside spread is not silently discarded");
    check(StructureWindow(0)<StructureWindow(1)&&StructureWindow(1)<StructureWindow(2),"separate structure profiles");
    check(ObservationHorizon(0)<ObservationHorizon(1)&&ObservationHorizon(1)<ObservationHorizon(2),"separate observation windows");
    check(PlanPricesValid(1,true,100,99.8,100.03,100.05,100.08,99.99,100,.01,.01,.01,1),"small M5 final target clears its own spread");
    check(PlanPricesValid(1,true,100,99.8,100.01,100.05,100.08,99.99,100,.01,.01,.01,1),"BUY TP1 equal to spread does not veto a valid TP3");
    check(PlanPricesValid(-1,true,100,100.2,99.97,99.95,99.92,100,100.01,.01,.01,.01,1),"small SELL final target clears its own spread");
    check(PlanPricesValid(-1,true,100,100.2,99.99,99.95,99.92,100,100.01,.01,.01,.01,1),"SELL TP1 equal to spread does not veto a valid TP3");
    check(PlanPriceIssue(-1,true,100,100.2,99.97,99.95,99.92,100,100.08,.01,.01,.01,1)=="TP3 <= spread", "exact SELL final-target spread failure");
    check(PlanPriceIssue(1,true,100,99.8,100.01,100.02,100.08,99.92,100,.01,.01,.01,1)=="TP3 <= spread", "BUY TP3 equal to spread holds");
    check(TargetClearsSpread(1,99.70,99.78,99.96,100,.01), "BUY pending stays when its final target clears spread");
    check(!TargetClearsSpread(1,99.70,99.78,99.92,100,.01), "BUY pending cancels when final target equals spread");
    check(TargetClearsSpread(-1,100.30,100.22,100,100.04,.01), "SELL pending stays when its final target clears spread");
    check(!TargetClearsSpread(-1,100.30,100.22,100,100.08,.01), "SELL pending cancels when final target equals spread");
    check(!TargetClearsSpread(1,100,100.08,99.99,100,0), "missing tick fails the pending spread check safely");
    check(PlanPriceIssue(1,true,100,99.8,100.03,100.03,100.08,99.99,100,.01,.01,.01,1)=="TP2 order/tick", "exact collapsed target failure");
    check(PlanPriceIssue(1,true,100,99.5,100.03,100.05,100.08,99.99,100,.01,.01,.10,1)=="TP3 broker minimum", "exact broker TP3 failure");
    check(PlanPriceIssue(1,false,99.99,99.5,100.02,100.05,100.08,99.99,100,.01,.01,.02,1)=="buy limit too close", "exact pending entry failure");
    check(PlanPriceIssue(-1,true,100,100.2,99.97,99.95,0,100,100.01,.01,.01,.01,1)=="invalid TP price", "non-positive SELL target rejected");

    // A nearby three-bar support is inside the spread. Do not silently
    // ignore it merely to make a trade or a target appear viable.
    std::vector<MqlRates> scalp;
    double slows[]={100.20,100.15,99.97,100.05,99.90,100.10,100.02,100.10,100.02,99.70,100.00,100.10};
    double shighs[]={100.30,100.40,100.30,100.50,100.30,100.60,100.30,100.70,100.30,100.80,100.30,100.50};
    for(int k=0;k<12;k++) scalp.push_back(bar((slows[k]+shighs[k])/2,shighs[k],slows[k]));
    check(ConfirmedSwingLow(scalp,2,11), "nearby support remains a confirmed swing");
    SStructureGeometry shortPlan{};
    check(StructureGeometry(scalp,11,0,-1,true,false,100,100.04,.01,.01,.01,shortPlan), "SELL scalp structure");
    check(eq(shortPlan.cap[0],.06) && eq(shortPlan.cap[1],.26) && eq(shortPlan.nearBarrier,100.01), "nearer support retains HOLD despite farther Ask-side caps");
    scalp[4].low=99.97; // another confirmed barrier is inside the spread
    SStructureGeometry blocked{};
    check(StructureGeometry(scalp,11,0,-1,true,false,100,100.04,.01,.01,.01,blocked), "confirmed near barrier structure");
    check(eq(blocked.nearBarrier,100.01), "confirmed support inside spread remains a HOLD barrier");
}

void test_hurst_prefix() {
    std::vector<double> c(4000);
    for(int i=0;i<(int)c.size();i++)
        c[i]=100*std::exp(.00002*i + .002*std::sin(i*.17) + .0003*std::sin(i*.43));
    c[1000]=0; // exactly the same skip behavior as the live estimator
    std::vector<double> prefix;
    ObservationReturnPrefix(c,prefix);
    for(int window : {256,512,1536})
        for(int last : {1600,2200,3500,3999}) {
            double slow=HurstExponent(c,last,window), fast=ObservationHurst(prefix,last,window);
            check(std::fabs(slow-fast)<1e-9,"causal Hurst-prefix agrees with live estimator");
        }
    auto before=ObservationHurst(prefix,2200,512);
    c[3999]=5000;ObservationReturnPrefix(c,prefix);
    check(std::fabs(ObservationHurst(prefix,2200,512)-before)<1e-12,"future prices cannot alter past regime");
}

void test_replay() {
    SStructureGeometry g{};g.entry=100;g.stop=99;
    double r=-1;
    std::vector<MqlRates> b={bar(100,150,1),bar(100,102,98),bar(100,110,99.5)};
    check(ReplayObservation(b,0,2,1,true,g,.01,.1,r)&&eq(r,0),"same-bar stop wins ambiguity");
    b[1]=bar(100,100.6,99.5);b[2]=bar(100,102,98.5);
    check(ReplayObservation(b,0,2,1,true,g,.01,.1,r)&&eq(r,.6),"pre-stop progress retained, post-stop ignored");
    check(!ReplayObservation(b,0,3,1,true,g,.01,.1,r),"incomplete horizon excluded");
    g.stop=101;b[1]=bar(100,100.5,99.4,10);b[2]=bar(100,102,98,10);
    check(ReplayObservation(b,0,2,-1,true,g,.01,.1,r)&&eq(r,.5),"sell favorable exit uses Ask");
    b[1]=bar(100,100.95,99.0,10);
    check(ReplayObservation(b,0,2,-1,true,g,.01,.1,r)&&eq(r,0),"sell stop uses Ask not Bid");
    g.stop=99;b[1]=bar(100.2,100.9,99.95,10);b[2]=bar(100,100.2,99.5,10);
    check(!ReplayObservation(b,0,2,1,false,g,.01,.1,r),"buy limit requires Ask touch");
    b[1].low=99.8;
    check(ReplayObservation(b,0,2,1,false,g,.01,.1,r)&&eq(r,.2),"ignore pre-fill favorable extreme");
    b[1].low=98;
    check(ReplayObservation(b,0,2,1,false,g,.01,.1,r)&&eq(r,0),"fill-bar stop wins ambiguity");
}

void test_persistence() {
    check(!BrokerExitsDiffer(99,103,99,103,.01),"identical broker exits cannot identify a software-only update");
    check(BrokerExitsDiffer(99,103,98.99,103,.01),"changed broker stop distinguishes the update journal");
    reset();
    const ulong huge=1234567890123456789UL;
    save_new_pending(huge);
    orderPosition[huge]=9001;
    broker_slot(9001,true,9001,99.90,99,103);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,101)&&eq(g_auto[0].tp2Price,102),"64-bit identity and absolute targets survive fill/restart");
    check(g_auto[0].tp1Pts==110 && g_auto[0].tp2Pts==210,"distances reflect actual slippage without moving targets");

    reset();save_new_pending();
    check(!RequestPendingCancellation(0) && g_auto[0].cancelPending,"rejected cancel sets sticky latch before request");
    broker_slot(42,false,0,100,99,103);RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(g_auto[0].cancelPending,"rejected pending cancellation survives restart");
    deleteAccepted=true;check(RequestPendingCancellation(0),"sticky cancellation retries successfully");

    reset();save_new_pending();failGlobal=true;
    check(!RequestPendingCancellation(0),"failed cancel remains active even when GV write fails");
    failGlobal=false;broker_slot(42,false,0,100,99,103);g_auto[0].newTradeMarker=true;
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(!g_auto[0].modernTargets,"failed latch invalidates restart ladder so the pending is not refreshed");
    reset();broker_slot(42,false,0,100,99,103);g_auto[0].legacyTradeMarker=true;
    RecoverSlotTargets(0,.01);
    check(!g_auto[0].modernTargets,"unversioned legacy pending is cancelled rather than guessed");

    reset();save_new_pending();
    check(BeginTargetUpdate(0,99.5,98.5,100.3,101.2,102.5),"journal new levels");
    broker_slot(42,false,0,100,99,103);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,101)&&eq(g_auto[0].tp2Price,102),"rejected modification keeps old targets");
    check(!GlobalVariableCheck(AutoGVKey(0,"uv")),"rejected journal reconciled");

    reset();save_new_pending();check(BeginTargetUpdate(0,99.5,98.5,100.3,101.2,102.5),"journal accepted case");
    broker_slot(42,false,0,99.5,98.5,102.5);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,100.3)&&eq(g_auto[0].tp2Price,101.2),"accepted modification recovered after crash");

    reset();save_new_pending();check(BeginTargetUpdate(0,99.5,98.5,100.3,101.2,102.5),"journal fill race");orderPosition[42]=88;
    broker_slot(88,true,88,99.4,98.5,102.5);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,100.3)&&eq(g_auto[0].tp2Price,101.2),"modified pending filled while offline");

    reset();save_new_pending();broker_slot(99,false,0,100,99,103);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(g_auto[0].tp1Price==0&&g_auto[0].tp2Price==0&&eq(g_auto[0].tpPrice,103),"wrong identity never invents staged exits");

    reset();broker_slot(42,true,42,100,99,103);g_auto[0].legacyTradeMarker=true;
    RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,101.69)&&eq(g_auto[0].tp2Price,102.25),"known legacy fallback remains unchanged");
    reset();broker_slot(42,true,42,100,99,103);g_auto[0].newTradeMarker=true;
    RecoverSlotTargets(0,.01);
    check(g_auto[0].tp1Price==0&&g_auto[0].tp2Price==0,"new order with lost state has no guessed ladder");

    reset();check(BeginTargetIntent(0,1,100,99,100.4,101.1,103),"write-ahead placement intent");
    broker_slot(42,true,42,100.02,99,103);
    RestoreAutoSlotState(0);RecoverSlotTargets(0,.01);
    check(eq(g_auto[0].tp1Price,100.4)&&eq(g_auto[0].tp2Price,101.1),"placement intent survives crash and slippage");
    reset();failGlobal=true;check(!BeginTargetIntent(0,1,100,99,101,102,103),"failed journal blocks order");
}

void prepare_position() {
    reset();broker_slot(42,true,42,100,99,103);auto &a=g_auto[0];a.modernTargets=true;a.tp1Price=101;a.tp2Price=102;
    brokerVolume=1;check(SaveAutoSlotState(0),"persist position before milestone");
}
void test_milestones() {
    prepare_position();positionExists=false;
    check(!ManageMilestone(0,1,true)&&closeCalls==0,"missing position never submits a close");
    positionExists=true;g_auto[0].ticket=0;
    check(!ManageMilestone(0,1,true)&&closeCalls==0,"zero ticket never submits an opposite open");
    prepare_position();responses={{0,0,false,false},{1,.70,false,true}};
    check(!ManageMilestone(0,1,true)&&!g_auto[0].tp1Hit&&closeCalls==1,"broker rejection leaves TP1 retryable");
    check(ManageMilestone(0,1,true)&&g_auto[0].tp1Hit&&closeCalls==2&&eq(brokerVolume,.30),"TP1 succeeds on retry");
    responses={{1,.29,false,true}};
    check(ManageMilestone(0,2,true)&&g_auto[0].tp2Hit&&eq(brokerVolume,.01),"TP2 leaves broker minimum");

    prepare_position();responses={{1,.20,false,true},{1,.50,false,true}};
    check(ManageMilestone(0,1,true)&&!g_auto[0].tp1Hit&&eq(brokerVolume,.8),"partial close does not prematurely mark TP1");
    check(ManageMilestone(0,1,true)&&g_auto[0].tp1Hit&&eq(brokerVolume,.3),"remaining partial retried without over-close");

    prepare_position();responses={{-1,0,true,false}};
    check(ManageMilestone(0,1,true)&&g_auto[0].tp1Awaiting&&!g_auto[0].tp1Hit,"unknown broker result waits");
    check(!ManageMilestone(0,1,true)&&closeCalls==1,"unknown result never sends a duplicate");
    brokerVolume=.30;g_auto[0].curLot=.30;
    check(ManageMilestone(0,1,false)&&g_auto[0].tp1Hit,"volume reconciliation completes after restart/unknown response");

    prepare_position();minimumLot=.1;responses={{1,.65,false,true}};
    check(ManageMilestone(0,1,true)&&!g_auto[0].tp1Hit,"partial before short residual");
    check(ManageMilestone(0,1,true)&&g_auto[0].tp1Hit&&g_auto[0].tp1Short&&closeCalls==1,"subminimum residual is explicit, not over-closed");

    prepare_position();
    StoreMilestone(0,1,1,.7,0,true);check(SaveAutoSlotState(0),"persist an in-flight close");
    g_auto[0].tp1Awaiting=false;g_auto[0].tp1DoneLot=.2;failKeys.insert(AutoGVKey(0,"c1"));
    check(!SaveAutoSlotState(0),"partially failed post-close save is reported");
    failKeys.clear();broker_slot(42,true,42,100,99,103);RestoreAutoSlotState(0);
    check(g_auto[0].tp1Awaiting,"failed reconciliation does not clear durable in-flight flag");

    prepare_position();failGlobal=true;check(!ManageMilestone(0,1,true)&&closeCalls==0,"failed journal prevents close request");
    reset();volumeStep=.25;minimumLot=.25;check(eq(FloorLotStep(.76),.75)&&eq(NormalizeLots(.76),.75),"non-decimal lot step precision");
}

void test_modification_confirmation() {
    reset();liveOrders={{42,100,"TEST",ORDER_TYPE_BUY_LIMIT,100,99,103}};
    check(!TradeModifyOrder(42,99.5,98.5,102.5),"rejected modification is not committed");
    modifyRetcode=TRADE_RETCODE_PLACED;modifyVisible=true;
    check(!TradeModifyOrder(42,99.5,98.5,102.5),"asynchronous PLACED is not confirmation");
    liveOrders[0].price=100;liveOrders[0].sl=99;liveOrders[0].tp=103;
    modifyRetcode=TRADE_RETCODE_DONE;modifyVisible=false;
    check(!TradeModifyOrder(42,99.5,98.5,102.5),"DONE without broker-visible levels remains uncertain");
    modifyVisible=true;
    check(TradeModifyOrder(42,99.5,98.5,102.5),"DONE with matching broker levels is confirmed");
    check(PendingLevelsMatch(42,99.5,98.5,102.5,.005),"modified levels are the broker-visible values");
}

void test_broker_end_proof() {
    reset();save_new_pending();
    check(!BrokerSlotEnded(0,false),"missing broker order/history is not proof of ending");
    orderStates[42]=ORDER_STATE_PLACED;
    check(!BrokerSlotEnded(0,false),"still-live order is not ended");
    orderStates[42]=ORDER_STATE_CANCELED;
    check(BrokerSlotEnded(0,false),"confirmed unfilled canceled order ended");
    orderPosition[42]=88;historyDeals={{1,88,DEAL_ENTRY_IN,.4}};
    check(!BrokerSlotEnded(0,false),"canceled remainder with open partial position is not ended");
    historyDeals.push_back({2,88,DEAL_ENTRY_OUT,.2});
    check(!BrokerSlotEnded(0,false),"partially closed position remains active");
    historyDeals.push_back({3,88,DEAL_ENTRY_OUT_BY,.2});
    check(BrokerSlotEnded(0,false),"complete history proves the filled position ended");
    connected=false;check(!BrokerSlotEnded(0,false),"disconnected terminal never proves closure");connected=true;
    historyAvailable=false;check(!BrokerSlotEnded(0,false),"missing history never proves closure");historyAvailable=true;
    historyDeals.push_back({4,88,DEAL_ENTRY_INOUT,.1});
    check(!BrokerSlotEnded(0,false),"reversal requires manual review");
}

void test_remainders() {
    reset();broker_slot(42,true,42,100,99,103);
    liveOrders={{42,100,"TEST",ORDER_TYPE_BUY_LIMIT},{43,101,"TEST",ORDER_TYPE_BUY_LIMIT},
                {44,100,"OTHER",ORDER_TYPE_BUY_LIMIT},{45,100,"TEST",ORDER_TYPE_SELL}};
    tradingAllowed=false;
    check(CancelEntryRemainders(0) && deleteCalls==0,"read-only mode observes but cannot cancel remainder");
    tradingAllowed=true;
    check(CancelEntryRemainders(0) && deleteCalls==1,"rejected remainder cancel stays outstanding");
    check(CancelEntryRemainders(0) && deleteCalls==1,"rejected remainder retries are throttled");
    clockMs+=2001;deleteAccepted=true;
    check(CancelEntryRemainders(0) && deleteCalls==2,"successful removal waits for next broker rescan");
    check(!CancelEntryRemainders(0) && liveOrders.size()==3,"other symbol/lane and opposite-side close orders untouched");
}
int main() { test_geometry();test_hurst_prefix();test_replay();test_persistence();test_milestones();test_modification_confirmation();test_broker_end_proof();test_remainders();std::puts("extracted structure, replay, persistence and milestone checks passed"); }
