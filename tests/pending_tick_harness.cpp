// Execute the production pending tick manager with controlled C++ stubs.
// This is not an MQL compiler or a broker/order-fill simulator.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
using string = std::string;
using ulong = unsigned long;
#define TF_COUNT 3
#define SYMBOL_POINT 1
#define SYMBOL_TRADE_TICK_SIZE 2
#define SYMBOL_BID 3
#define SYMBOL_ASK 4
#define MathMax(a,b) std::fmax((a),(b))

struct AutoSlot {
    bool active=false, isOpen=false, marketInFlight=false, cancelPending=false;
    bool multiplePositions=false, residualOrder=false;
    bool tp1Hit=false, tp2Hit=false, tp1Skipped=false, tp2Skipped=false;
    int dir=0;
    double entryPrice=0, slPrice=0, tpPrice=0, tp1Price=0, tp2Price=0;
} g_auto[TF_COUNT];
struct Plan { int state=2,dir=1; } g_plans[TF_COUNT];
struct Row { bool ok=true; int direction=1; string tag="M5"; } g_rows[TF_COUNT];
string _Symbol="TEST";
double testPoint=.01, testTick=.01, testBid=99.96, testAsk=100;
bool g_autoShown=true, tradingAllowed=true, laneEnabled=true, regimeBlocked=false;
bool timerAllowed=true, trendAllowed=true, cancelAccepted=true;
ulong clockMs=3000, g_lastSafetyCancelMs[TF_COUNT]={};
int cancelRequests=0, closeStages=0;

double SymbolInfoDouble(const string&, int field) {
    return field==SYMBOL_POINT ? testPoint : field==SYMBOL_TRADE_TICK_SIZE ? testTick
         : field==SYMBOL_BID ? testBid : field==SYMBOL_ASK ? testAsk : 0;
}
bool AnyAutoActive() { for(auto &a:g_auto) if(a.active) return true; return false; }
void SyncAutoState() {}
bool CanTradeNow() { return tradingAllowed; }
bool AutoTradingAllowed(int) { return laneEnabled; }
bool RegimeBlocksEntry(int) { return regimeBlocked; }
bool AutoTimerAllowsPlacement() { return timerAllowed; }
bool TrendMatchForTF(int) { return trendAllowed; }
ulong GetTickCount64() { return clockMs; }
bool RequestPendingCancellation(int i) {
    ++cancelRequests;
    g_auto[i].cancelPending=true; // sticky even when the broker rejects deletion
    return cancelAccepted;
}
void DiaryUpdateOpenSlot(int,double,bool) {}
bool SaveAutoSlotState(int) { return true; }
bool ManageMilestone(int,int,bool reached) { if(reached) ++closeStages; return false; }
template<class... A> void PrintFormat(const char*,A...) {}
void UpdatePlan() {}
void UpdateAutoPanel() {}
void DrawSupportedPanel() {}
void DrawAutoPanel() {}
void ChartRedraw(int) {}

#include "extracted.hpp"

void check(bool ok,const char *message) {
    if(!ok) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
void reset(int dir) {
    for(int i=0;i<TF_COUNT;i++) {
        g_auto[i]=AutoSlot{};g_plans[i]=Plan{};g_rows[i]=Row{};g_lastSafetyCancelMs[i]=0;
    }
    testPoint=testTick=.01;testBid=99.96;testAsk=100;
    tradingAllowed=laneEnabled=timerAllowed=trendAllowed=cancelAccepted=true;
    regimeBlocked=false;g_autoShown=true;clockMs=3000;cancelRequests=closeStages=0;
    g_auto[0].active=true;g_auto[0].dir=dir;
    g_rows[0].direction=dir;g_plans[0].dir=dir;
    if(dir>0) {
        g_auto[0].entryPrice=99.70;g_auto[0].slPrice=99.20;
        g_auto[0].tp1Price=99.71;g_auto[0].tp2Price=99.74;g_auto[0].tpPrice=99.78;
    } else {
        testBid=100;testAsk=100.04;
        g_auto[0].entryPrice=100.30;g_auto[0].slPrice=100.80;
        g_auto[0].tp1Price=100.29;g_auto[0].tp2Price=100.26;g_auto[0].tpPrice=100.22;
    }
}
int main() {
    reset(1);
    ManageAutoTick();
    check(cancelRequests==0,"BUY pending keeps its small TP1 when TP3 clears spread");
    testBid=99.92;
    ManageAutoTick();
    check(cancelRequests==1 && g_auto[0].cancelPending,"BUY pending cancels when TP3 equals spread");

    reset(-1);
    ManageAutoTick();
    check(cancelRequests==0,"SELL pending keeps its small TP1 when TP3 clears spread");
    testAsk=100.08;
    ManageAutoTick();
    check(cancelRequests==1 && g_auto[0].cancelPending,"SELL pending cancels when TP3 equals spread");

    reset(1);testTick=0;
    ManageAutoTick();
    check(cancelRequests==1,"pending entry fails closed when its tick size is unavailable");

    reset(1);g_plans[0].state=0;
    ManageAutoTick();
    check(cancelRequests==1,"other plan HOLD still cancels a pending entry");

    reset(1);testBid=99.92;cancelAccepted=false;
    ManageAutoTick();
    check(cancelRequests==1 && g_auto[0].cancelPending,"failed deletion stays latched");
    testBid=99.96;clockMs=6000;
    ManageAutoTick();
    check(cancelRequests==2,"latched cancellation is retried after spread recovers");

    reset(1);g_auto[0].isOpen=true;testBid=99.60;testAsk=99.68;
    const double tp1=g_auto[0].tp1Price,tp3=g_auto[0].tpPrice;
    ManageAutoTick();
    check(cancelRequests==0 && closeStages==0 && g_auto[0].tp1Price==tp1 && g_auto[0].tpPrice==tp3,
          "widened spread does not cancel or reprice an already-open position");
    std::puts("extracted pending tick spread checks passed");
}
