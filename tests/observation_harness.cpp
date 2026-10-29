// Runs the extracted production ObserveLane pipeline with deterministic
// synthetic Bid bars. These stubs are not an MT5 compiler or broker.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
using string = std::string;
using datetime = long long;
#define MathMax(a,b) std::fmax((a),(b))
#define MathMin(a,b) std::fmin((a),(b))
#define MathAbs(a) std::fabs(a)
#define MathFloor(a) std::floor(a)
#define MathCeil(a) std::ceil(a)
#define MathLog(a) std::log(a)
#define MathSqrt(a) std::sqrt(a)
#define MathExp(a) std::exp(a)
#define MathCos(a) std::cos(a)
double MathRound(double a) { return std::round(a); }
double NormPrice(double x) { return std::round(x*100)/100; }
template<class T> int ArraySize(const std::vector<T> &v) { return static_cast<int>(v.size()); }
template<class T> void ArrayResize(std::vector<T> &v, int n) { v.resize(n); }
template<class T, class V> void ArrayInitialize(std::vector<T> &v, V x) { std::fill(v.begin(),v.end(),x); }
template<class T> void ArraySort(std::vector<T> &v) { std::sort(v.begin(),v.end()); }
template<class T> void ArraySetAsSeries(std::vector<T>&, bool) {}
#define ZeroMemory(a) ((a) = {})
#define STRUCTURE_M5 36
#define STRUCTURE_M15 48
#define STRUCTURE_M30 72
#define OBS_HORIZON_M5 4
#define OBS_HORIZON_M15 6
#define OBS_HORIZON_M30 8
#define OBS_HISTORY_BARS 12000
#define OBS_MIN_CASES 30
#define OBS_Q1 .50
#define OBS_Q2 .70
#define OBS_Q3 .85
#define TREND_L2 24
#define RANGE_BARS 20
#define RANGE_ER_MAX .40
#define ATR_PERIOD 14
#define VOL_RATIO_MIN .50
#define ER_PERIOD 20
#define ER_DEAD .10
#define ROC_DEAD_ATR .02
#define STRUCT_PERIOD 20
#define STRUCT_DEAD_ATR .25
struct MqlRates { datetime time=0; double open=0,high=0,low=0,close=0; int spread=0; long tick_volume=0; };
struct SStructureGeometry { double entry=0,stop=0,cap[3]={}; };
struct SObservationCache { datetime bar=0; int dir=0,score=0,regime=0,regimeSrc=0; bool market=false,range=false; int eligible=0,filled=0; double q1=0,q2=0,q3=0; } g_observations[3];
struct Row { int tf=0,hWindow=0,regime=0,regimeSrc=-1; double hTrend=100,hRevert=-100; datetime lastBar=1; } g_rows[3];
string _Symbol="SYNTHETIC";
int InpBuyScore=2, InpSellScore=-2;
bool InpRangeMode=true;
std::vector<MqlRates> fixture[3];
int reads=0;
int PeriodSeconds(int tf) { return tf; }
int CopyRates(const string&, int tf, int, int n, std::vector<MqlRates> &out) {
    ++reads;
    int i=tf==300?0:tf==900?1:2;
    const auto &src=fixture[i];
    auto first=src.size() > (size_t)n ? src.end()-n : src.begin();
    out.assign(first,src.end());
    return static_cast<int>(out.size());
}
#include "extracted.hpp"
void check(bool ok, const char *message) { if(!ok){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);} }
void make_history(int i, int n) {
    fixture[i].clear(); fixture[i].reserve(n);
    int sec=g_rows[i].tf;
    for(int k=0;k<n;k++) {
        double c=100 + .0002*k + .75*std::sin(k*.071) + .19*std::sin(k*.31) + .07*std::sin(k*.91);
        double prev=100 + .0002*(k-1) + .75*std::sin((k-1)*.071) + .19*std::sin((k-1)*.31) + .07*std::sin((k-1)*.91);
        MqlRates b; b.time=(datetime)(k+1)*sec; b.open=prev; b.close=c;
        b.high=std::max(prev,c)+.04+.015*(1+std::sin(k*.2));
        b.low=std::min(prev,c)-.04-.015*(1+std::cos(k*.3));
        b.spread=1; b.tick_volume=100+(k%30); fixture[i].push_back(b);
    }
}
int main() {
    g_rows[0].tf=300;g_rows[0].hWindow=1536;
    g_rows[1].tf=900;g_rows[1].hWindow=512;
    g_rows[2].tf=1800;g_rows[2].hWindow=256;
    for(int i=0;i<3;i++){make_history(i,12000);g_rows[i].lastBar=fixture[i].back().time;}
    auto start=std::chrono::steady_clock::now();
    int enough=0, validPlans=0;
    for(int i=0;i<3;i++) {
        ObserveLane(i,1,3,true,false,.01,.01,.01,.01);
        auto o=g_observations[i];
        check(o.bar==g_rows[i].lastBar,"completed history cached against the closed bar");
        check(o.eligible>=o.filled,"touch count cannot exceed eligible setups");
        check(o.q1<=o.q2 && o.q2<=o.q3,"observed quantiles sorted");
        if(o.filled>=OBS_MIN_CASES) ++enough;
        // Use actual replay quantiles and structure to show that at least
        // one synthetic plan can pass the same production price checks.
        for(int last=11999;last>11499 && o.q1>0;last--) {
            auto &bars=fixture[i];double bid=bars[last].close,ask=bid+.01;
            SStructureGeometry geo{};
            if(!StructureGeometry(bars,last,i,1,true,false,bid,ask,.01,.01,.01,geo))continue;
            double risk=geo.entry-geo.stop;
            double d[3]={risk*o.q1,risk*o.q2,risk*o.q3};
            for(int k=0;k<3;k++)if(geo.cap[k]>0)d[k]=std::min(d[k],geo.cap[k]);
            double t1=PriceDown(geo.entry+d[0],.01),t2=PriceDown(geo.entry+d[1],.01),t3=PriceDown(geo.entry+d[2],.01);
            if(PlanPricesValid(1,true,geo.entry,geo.stop,t1,t2,t3,bid,ask,.01,.01,.01,1)) {++validPlans;break;}
        }
        int oldReads=reads;
        ObserveLane(i,1,3,true,false,.01,.01,.01,.01);
        check(reads==oldReads,"same-bar identical replay uses cache");
        std::printf("lane %d: %d/%d, q %.3f %.3f %.3f\n",i,o.filled,o.eligible,o.q1,o.q2,o.q3);
    }
    check(enough>0,"full observation pipeline finds enough synthetic analogs in at least one lane");
    check(validPlans>0,"structure plus observed quantiles can produce a valid synthetic plan");
    ObserveLane(1,-1,-3,true,false,.01,.01,.01,.01);
    check(g_observations[1].filled>0 && g_observations[1].dir==-1,"full SELL replay has completed observations");
    ObserveLane(1,1,2,false,false,.01,.01,.01,.01);
    check(g_observations[1].eligible>=g_observations[1].filled,"pending touch count cannot exceed eligible setups");
    fixture[0].resize(900);g_rows[0].lastBar++;
    ObserveLane(0,1,3,true,false,.01,.01,.01,.01);
    check(g_observations[0].bar==0 && g_observations[0].filled==0,"short history is not cached as adequate evidence");
    make_history(0,12000);g_rows[0].lastBar=fixture[0].back().time;
    // M5's borrowed regime must use only a slower bar completed at the decision.
    std::vector<MqlRates> src(3);
    src[0].time=1000;src[1].time=1900;src[2].time=2800;
    check(ObservationSourceIndex(src,2799,900)==0,"unfinished source bar excluded");
    check(ObservationSourceIndex(src,2800,900)==1,"source bar eligible exactly on close");
    g_rows[0].regimeSrc=1;g_rows[0].lastBar++;
    ObserveLane(0,1,3,true,false,.01,.01,.01,.01);
    check(g_observations[0].bar==g_rows[0].lastBar && g_observations[0].regimeSrc==1,
          "borrowed regime completes without using an open slower bar");
    auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
    std::printf("full synthetic observation pipeline passed (%lld ms; C++ stub timing only)\n",(long long)ms);
}
