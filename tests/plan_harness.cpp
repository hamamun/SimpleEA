// Executes the production UpdatePlanRow / HOLD display / placement gate
// against controlled C++ stubs. Not an MQL compiler or a broker simulator.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
using string = std::string;
using datetime = long long;
using color = int;
#define MathMax(a,b) std::fmax((a),(b))
#define MathMin(a,b) std::fmin((a),(b))
#define MathAbs(a) std::fabs(a)
#define MathRound(a) std::round(a)
#define PLAN_LINES 4
#define OBS_MIN_CASES 30
#define RANGE_VALID_BARS 8
#define VALID_BARS 3
#define RISK_SCORE3_X 2.0
#define BAL_PER_001 1000.0
#define SCORE3_FACTOR 1.5
#define SYMBOL_POINT 1
#define SYMBOL_TRADE_TICK_SIZE 2
#define SYMBOL_BID 3
#define SYMBOL_ASK 4
#define SYMBOL_VOLUME_MIN 5
#define SYMBOL_VOLUME_MAX 6
#define SYMBOL_VOLUME_STEP 7
#define SYMBOL_CHART_MODE 8
#define SYMBOL_CHART_MODE_BID 0
#define SYMBOL_TRADE_STOPS_LEVEL 9
#define SYMBOL_DIGITS 10
#define ACCOUNT_MARGIN_MODE 11
#define ACCOUNT_MARGIN_MODE_RETAIL_HEDGING 12
#define ACCOUNT_BALANCE 13
#define ACCOUNT_CURRENCY 14
using ENUM_SYMBOL_CHART_MODE = int;
const color clrGray=1, clrSilver=2, InpTitleColor=3, InpBuyColor=4, InpSellColor=5, clrOrange=6;

struct MqlRates { double close=0; };
struct SStructureGeometry { double entry=0,stop=0,cap[3]={},nearBarrier=0; int issue=0; };
struct SObservationCache { int filled=40,eligible=50; double q1=.5,q2=1,q3=1.5; };
struct Row {
    bool ok=true;
    int direction=1,score=3,tf=300,mode=0;
    string tag="M5",blockReason="";
    datetime lastBar=10000,sigBirth=10000;
} g_rows[3];
struct SPlanRow {
    int state=0,dir=0,score=0,lines=1,slPts=0,tpPts=0,tp1Pts=0,tp2Pts=0,tp3Pts=0;
    bool market=false;
    string head,kind,note,lbl[PLAN_LINES][3],val[PLAN_LINES][3];
    double entryPrice=0,slPrice=0,tp1Price=0,tp2Price=0,tp3Price=0,lot=0;
    datetime validUntil=0;
    color clr[PLAN_LINES][3]={};
} g_plans[3];
SObservationCache g_observations[3], testObs;
string _Symbol="SYNTHETIC";
bool InpAutoTrading=true,InpUseRisk=true,InpUseMinLot=false;
double InpRiskPct=.5;
bool laneEnabled=true,regimeBlocked=false,trendMatch=true,timerAllowed=true;
bool terminalAllowed=true,openPosition=false,uncertainOrder=false,hasHistory=true,geometryOK=true,hasCaps=true;
int accountMode=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING,symbolDigits=2,stopLevel=1;
double point=.01,tick=.01,bid=99.99,ask=100,balance=10000,pv=1,minLot=.01;
double geometryRisk=.5, testBarrier=0, cap0=.30, cap1=.60, cap2=.90;

const char *format_arg(const string &v) { return v.c_str(); }
template<class T> T format_arg(T v) { return v; }
template<class... A> string StringFormat(const char *fmt, A... args) {
    char buf[512]; std::snprintf(buf,sizeof(buf),fmt,format_arg(args)...); return buf;
}
string DoubleToString(double n,int digits) {
    char buf[80]; std::snprintf(buf,sizeof(buf),"%.*f",digits,n); return buf;
}
template<class T> void ArraySetAsSeries(std::vector<T>&,bool) {}
double SymbolInfoDouble(const string&,int field) {
    switch(field) {
        case SYMBOL_POINT:return point; case SYMBOL_TRADE_TICK_SIZE:return tick;
        case SYMBOL_BID:return bid; case SYMBOL_ASK:return ask;
        case SYMBOL_VOLUME_MIN:return minLot; case SYMBOL_VOLUME_MAX:return 100;
        case SYMBOL_VOLUME_STEP:return .01; default:return 0;
    }
}
long SymbolInfoInteger(const string&,int field) {
    if(field==SYMBOL_DIGITS)return symbolDigits;
    if(field==SYMBOL_CHART_MODE)return SYMBOL_CHART_MODE_BID;
    if(field==SYMBOL_TRADE_STOPS_LEVEL)return stopLevel;
    return 0;
}
long AccountInfoInteger(int) { return accountMode; }
double AccountInfoDouble(int) { return balance; }
string AccountInfoString(int) { return "USD"; }
double PointValuePerLot() { return pv; }
bool AutoTradingAllowed(int) { return laneEnabled; }
bool RegimeBlocksEntry(int) { return regimeBlocked; }
bool TrendMatchForTF(int) { return trendMatch; }
bool AutoTimerAllowsPlacement() { return timerAllowed; }
bool CanTradeNow() { return InpAutoTrading && terminalAllowed; }
bool PlanHasOpenPosition(int) { return openPosition; }
bool PlanHasUncertainOrder(int) { return uncertainOrder; }
bool IsVolumeConfirmed(int,int) { return true; }
int StructureWindow(int i) { return i==0 ? 36 : i==1 ? 48 : 72; }
int ObservationHorizon(int i) { return i==0 ? 4 : i==1 ? 6 : 8; }
int PeriodSeconds(int tf) { return tf; }
int CopyRates(const string&,int,int,int n,std::vector<MqlRates> &out) {
    out.assign(hasHistory ? n : n-1, MqlRates{}); return static_cast<int>(out.size());
}
double PriceDown(double p,double t) { return std::floor(p/t+1e-8)*t; }
double PriceUp(double p,double t) { return std::ceil(p/t-1e-8)*t; }
bool StructureGeometry(const std::vector<MqlRates>&,int,int,int dir,bool market,bool,
                       double bidNow,double askNow,double,double,double,SStructureGeometry &out) {
    out = {};
    out.entry=market ? (dir>0 ? askNow : bidNow) : (dir>0 ? 99.70 : 100.30);
    if(!geometryOK){out.issue=4;return false;} // no stop swing
    out.stop=out.entry-dir*geometryRisk;
    out.nearBarrier=testBarrier;
    if(hasCaps) {out.cap[0]=cap0;out.cap[1]=cap1;out.cap[2]=cap2;}
    return true;
}
void ObserveLane(int i,int,int,bool,bool,double,double,double,double) { g_observations[i]=testObs; }
double SymbolMinLot() { return minLot; }
double NormalizeLots(double n) { return std::fmax(minLot,std::floor(n*100+1e-8)/100); }
double ExistingPendingVolume(int,int) { return 0; }
double FloorLotStep(double n) { return std::fmax(0,std::floor(n*100+1e-8)/100); }
double CalcTP1CloseLot(double n) { return FloorLotStep(n*.7); }
double CalcTP2CloseLot(double n) { return FloorLotStep(n-minLot); }

#include "extracted.hpp"
void check(bool ok,const char *what) {
    if(!ok){std::fprintf(stderr,"FAIL: %s\n",what);std::exit(1);}
}
bool eq(double a,double b) { return std::fabs(a-b)<1e-6; }
void reset() {
    InpAutoTrading=true; InpUseRisk=true; InpUseMinLot=false; InpRiskPct=.5;
    laneEnabled=true;regimeBlocked=false;trendMatch=true;timerAllowed=true;terminalAllowed=true;
    openPosition=false;uncertainOrder=false;hasHistory=true;geometryOK=true;hasCaps=true;
    accountMode=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;point=.01;tick=.01;bid=99.99;ask=100;
    balance=10000;pv=1;minLot=.01;testObs=SObservationCache{};
    symbolDigits=2;stopLevel=1;geometryRisk=.5;testBarrier=0;cap0=.30;cap1=.60;cap2=.90;
    for(int i=0;i<3;i++){g_rows[i]=Row{};g_plans[i]=SPlanRow{};g_observations[i]=SObservationCache{};}
}
void check_veto(const string &reason) {
    UpdatePlanRow(0);
    check(g_rows[0].direction==1,"veto does not change BUY signal");
    check(g_plans[0].state==0 && g_plans[0].kind=="HOLD","veto retains HOLD");
    check(g_plans[0].val[3][0]==reason,"veto reason displayed");
    check(g_plans[0].entryPrice>0 && g_plans[0].slPrice>0 && g_plans[0].tp3Price>0,
          "valid prices remain visible despite a permission veto");
}
int main() {
    reset();
    check(CanPlaceAutoOrders(),"master on and timer open enable new entries by default");
    UpdatePlanRow(0);
    check(g_plans[0].state==2 && g_plans[0].kind=="market +3/3","default BUY produces active plan");
    check(eq(g_plans[0].entryPrice,100) && eq(g_plans[0].slPrice,99.5),"active entry and stop");
    check(eq(g_plans[0].tp1Price,100.25) && eq(g_plans[0].tp2Price,100.5) && eq(g_plans[0].tp3Price,100.75),"three observed targets");
    check(g_plans[0].val[0][2]=="40/50 analogs", "completed analog counts visible");
    check(g_plans[0].val[1][0].find("99.50")==0 && g_plans[0].val[1][1].find("100.25")==0 &&
          g_plans[0].val[1][2].find("100.50")==0 && g_plans[0].val[2][0].find("100.75")==0,
          "active stop and all three targets displayed");
    check(g_plans[0].lbl[3][2]=="Fees:" && g_plans[0].val[3][2]=="not included", "unknown fees disclosed");
    check(g_plans[0].val[2][1].find("(est)")!=string::npos && g_plans[0].val[2][2].find("(est)")!=string::npos,"risk and reward labeled estimates");

    reset();testObs.filled=29;UpdatePlanRow(0);
    check(g_rows[0].direction==1 && g_plans[0].state==0 && g_plans[0].kind=="HOLD","insufficient history keeps BUY but blocks trading");
    check(g_plans[0].val[0][0]=="100.00" && g_plans[0].val[0][1]=="99.50","held candidate entry and stop visible");
    check(g_plans[0].lbl[1][0]=="TP1~:" && g_plans[0].val[1][0]=="100.30 30.0pts", "actual swing barrier and directed distance are indicative only");
    check(g_plans[0].val[2][0]=="swing-only" && g_plans[0].val[2][1]=="NO ORDER", "no unsupported executable TP");
    check(g_plans[0].entryPrice==0 && g_plans[0].tp1Price==0,"preview does not populate executable prices");
    check(g_plans[0].val[0][2]=="29/50 analogs", "insufficient analog count is honest");

    reset();testObs.filled=0;hasCaps=false;UpdatePlanRow(0);
    check(g_plans[0].val[1][0]=="--" && g_plans[0].val[1][2]=="--", "missing swings do not invent targets");
    reset();geometryOK=false;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[0][1]=="--" && g_plans[0].val[1][0]=="--", "missing structure does not invent stop or targets");
    check(g_plans[0].val[3][0]=="no stop swing" && g_plans[0].val[2][2]=="1.0 pts", "geometry failure and spread are specific");
    reset();hasHistory=false;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].lines==1 && g_plans[0].note=="closed-bar structure still loading", "short structure history holds");
    reset();testObs.q1=0;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="weak follow-through", "weak observations hold");
    reset();testObs.q1=.01;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="TP1 order/tick", "collapsed TP1 gets exact reason");
    check(g_plans[0].lbl[2][2]=="Spread:" && g_plans[0].val[2][2]=="1.0 pts", "held plan shows spread at evaluation");
    check(g_plans[0].lbl[3][1]=="RawTP3:" && g_plans[0].val[3][1]=="75.0 pts", "uncapped main target distance visible");
    check(g_plans[0].lbl[3][2]=="Broker:" && g_plans[0].val[3][2]=="min 1.0 / tick 1.0 pts", "broker stop level and tick visible");
    reset();testObs.q1=.02;UpdatePlanRow(0);
    check(g_plans[0].state==2 && eq(g_plans[0].tp1Price,100.01), "TP1 equal to spread does not veto a viable TP3");
    check(g_plans[0].lbl[3][2]=="Fees:" && g_plans[0].val[3][2]=="excluded; TP1 small" && g_plans[0].clr[3][2]==clrOrange,
          "small TP1 warns about fees without holding the plan");
    reset();cap0=.01;UpdatePlanRow(0);
    check(g_plans[0].state==2 && eq(g_plans[0].tp1Price,100.01) && eq(g_plans[0].tp3Price,100.75),
          "a swing-capped TP1 does not veto the main target");
    check(g_plans[0].val[3][2]=="excluded; TP1 small", "capped TP1 still shows the cost warning");
    reset();bid=99.96;testObs.q1=.02;testObs.q2=.04;testObs.q3=.06;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="TP3 <= spread", "final target inside spread holds");
    check(g_plans[0].val[1][2]=="100.03 3.0pts" && g_plans[0].val[2][2]=="4.0 pts" &&
          g_plans[0].val[3][1]=="3.0 pts" && g_plans[0].val[2][1]=="NO ORDER", "held preview compares TP3 and spread");
    reset();bid=99.96;testObs.q1=.02;testObs.q2=.04;testObs.q3=.08;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="TP3 <= spread", "final target exactly at spread still holds");
    reset();bid=99.90;cap0=.03;cap1=.04;cap2=.05;testObs.q1=.06;testObs.q2=.08;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="TP3 <= spread", "capped final target still obeys spread");
    check(g_plans[0].val[2][0]=="observed + swing" && g_plans[0].val[3][1]=="75.0 pts", "final swing cap distinguished from raw target");
    reset();testBarrier=99.99;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="swing in spread", "confirmed near barrier holds");
    check(g_plans[0].lbl[3][1]=="Swing:" && g_plans[0].val[3][1]=="99.99", "actual near barrier displayed");
    reset();testBarrier=99.99;testObs.q1=.01;UpdatePlanRow(0);
    check(g_plans[0].val[3][0]=="swing in spread", "structural barrier is checked before target grid");

    // The screenshot-like levels are synthetic: the actual broker spread,
    // original observed quantiles and structure are not known from the image.
    reset();symbolDigits=5;point=tick=.00001;bid=1.11365;ask=1.11369;geometryRisk=.00067;
    g_rows[0].direction=-1;g_rows[0].score=-3;testObs.filled=207;testObs.eligible=207;
    testObs.q1=.00003/.00067;testObs.q2=.00018/.00067;testObs.q3=.00038/.00067;UpdatePlanRow(0);
    check(g_rows[0].direction==-1 && g_plans[0].state==2, "M5 SELL can pass when TP1 is inside spread but TP3 is not");
    check(g_plans[0].val[0][0]=="1.11365" && g_plans[0].val[1][0]=="1.11432 67pts" &&
          g_plans[0].val[1][1]=="1.11362 3pts" && g_plans[0].val[2][0]=="1.11327 38pts", "screenshot-like M5 levels retained");
    check(g_plans[0].val[3][2]=="excluded; TP1 small", "M5 short partial carries a warning");
    reset();symbolDigits=5;point=tick=.00001;bid=1.11365;ask=1.11369;geometryRisk=.00025;
    g_rows[2].direction=-1;g_rows[2].score=-3;g_rows[2].tag="M30";g_rows[2].tf=1800;
    testObs.filled=78;testObs.eligible=78;testObs.q1=.00002/.00025;testObs.q2=.00007/.00025;testObs.q3=.00021/.00025;UpdatePlanRow(2);
    check(g_plans[2].state==2 && g_plans[2].val[1][0]=="1.11390 25pts" &&
          g_plans[2].val[1][1]=="1.11363 2pts" && g_plans[2].val[2][0]=="1.11344 21pts", "screenshot-like M30 TP3 governs spread");
    check(g_plans[2].val[3][2]=="excluded; TP1 small", "M30 short partial carries a warning");

    reset();balance=10;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].val[3][0]=="risk exceeds budget", "minimum lot over budget holds");

    reset();accountMode=0;check_veto("hedging required");
    reset();laneEnabled=false;check_veto("lane switched off");
    reset();regimeBlocked=true;check_veto("regime blocks entry");
    reset();trendMatch=false;check_veto("trend gate mismatch");
    reset();timerAllowed=false;check(!CanPlaceAutoOrders(),"timer remains an entry gate");check_veto("timer paused");
    reset();InpAutoTrading=false;check(!CanPlaceAutoOrders(),"master off blocks orders");UpdatePlanRow(0);
    check(g_plans[0].state==2 && g_plans[0].entryPrice>0,"master off still previews plans");
    reset();terminalAllowed=false;check(!CanPlaceAutoOrders(),"terminal permission remains necessary");

    reset();g_rows[0].direction=-1;g_rows[0].score=-3;UpdatePlanRow(0);
    check(g_plans[0].state==2 && g_plans[0].slPrice>g_plans[0].entryPrice && g_plans[0].tp3Price<g_plans[0].tp2Price && g_plans[0].tp2Price<g_plans[0].tp1Price,"SELL exits ordered around entry");
    reset();g_rows[0].score=2;UpdatePlanRow(0);
    check(g_plans[0].state==2 && !g_plans[0].market && eq(g_plans[0].entryPrice,99.7),"eligible pending plan also enabled");
    reset();g_rows[0].direction=-1;g_rows[0].score=-2;UpdatePlanRow(0);
    check(g_plans[0].state==2 && !g_plans[0].market && eq(g_plans[0].entryPrice,100.3),"eligible SELL pending plan also enabled");
    reset();bid=99.96;testObs.q1=.02;testObs.q2=.08;testObs.q3=.16;g_rows[0].score=2;UpdatePlanRow(0);
    check(g_plans[0].state==2 && !g_plans[0].market && eq(g_plans[0].tp1Price,99.71) &&
          eq(g_plans[0].tp3Price,99.78) && g_plans[0].val[3][2]=="excluded; TP1 small", "BUY pending accepts short TP1 when TP3 clears spread");
    reset();bid=100;ask=100.04;testObs.q1=.02;testObs.q2=.08;testObs.q3=.16;g_rows[0].direction=-1;g_rows[0].score=-2;UpdatePlanRow(0);
    check(g_plans[0].state==2 && !g_plans[0].market && eq(g_plans[0].tp1Price,100.29) &&
          eq(g_plans[0].tp3Price,100.22) && g_plans[0].val[3][2]=="excluded; TP1 small", "SELL pending accepts short TP1 when TP3 clears spread");
    reset();g_rows[0].direction=0;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].lines==1,"signal HOLD has no fabricated plan");
    reset();openPosition=true;UpdatePlanRow(0);
    check(g_plans[0].state==0 && g_plans[0].note.find("existing exits retained")!=string::npos,"open positions are not replanned");
    std::puts("extracted plan defaults, held previews, spread and permissions passed");
}
