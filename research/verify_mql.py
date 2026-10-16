"""Transcribe the MQL5 functions EXACTLY as written in SimpleAdvisor.mq5 and
check they agree with the validated reference engine (engine.py)."""
import numpy as np
from engine import highpass3, precision_trend, efficiency_ratio, load_csv

PI = 3.14159265358979323846

def MQL_HighPass3(price, period):
    """Literal transcription of HighPass3() in SimpleAdvisor.mq5."""
    n=len(price); hp=np.zeros(n)
    if n<3 or period<2: return hp
    f  = 1.414*PI/period
    a1 = np.exp(-f)
    c2 = 2.0*a1*np.cos(f)
    c3 = -a1*a1
    c1 = (1.0+c2-c3)/4.0
    for i in range(2,n):
        hp[i] = c1*(price[i]-2.0*price[i-1]+price[i-2]) + c2*hp[i-1] + c3*hp[i-2]
    return hp

def MQL_PrecisionTrend(close,l1,l2):
    hp1=MQL_HighPass3(close,l1); hp2=MQL_HighPass3(close,l2)
    trend=hp1-hp2
    roc=np.zeros(len(close))
    for i in range(1,len(close)): roc[i]=(l2/6.28)*(trend[i]-trend[i-1])
    return trend,roc

def MQL_EfficiencyRatio(close,i,n):
    if i<n or n<1: return 0.0
    path=0.0
    for k in range(i-n+1,i+1): path+=abs(close[k]-close[k-1])
    if path<=0.0: return 0.0
    return abs(close[i]-close[i-n])/path

def hurst_varscale(close,w=256,scales=(1,2,4,8,16)):
    n=len(close); out=np.full(n,np.nan)
    lr=np.zeros(n); lr[1:]=np.log(close[1:]/close[:-1])
    ls=np.log(np.array(scales,float))
    for i in range(w,n):
        x=lr[i-w+1:i+1]
        st=[]
        for s in scales:
            k=len(x)//s
            if k<4: st.append(np.nan); continue
            st.append(x[:k*s].reshape(k,s).sum(axis=1).std(ddof=1))
        st=np.array(st); ok=np.isfinite(st)&(st>0)
        if ok.sum()>=3: out[i]=np.polyfit(ls[ok],np.log(st[ok]),1)[0]
    return out

def MQL_Hurst(close,i,window):
    """Literal transcription of HurstExponent() in SimpleAdvisor.mq5."""
    if i+1<window or window<32: return 0.5
    scales=[1,2,4,8,16]; lx=[]; ly=[]; start=i-window+1
    for scale in scales:
        k=window//scale
        if k<4: continue
        sums=np.zeros(k)
        for b in range(k):
            s=0.0
            for j in range(scale):
                idx=start+b*scale+j
                p1=close[idx]; p0=close[idx-1]
                if p0>0.0 and p1>0.0: s+=np.log(p1/p0)
            sums[b]=s
        mean=sums.mean()
        var=((sums-mean)**2).sum()/(k-1)
        sd=np.sqrt(var)
        if sd<=0.0: continue
        lx.append(np.log(scale)); ly.append(np.log(sd))
    if len(lx)<3: return 0.5
    lx=np.array(lx); ly=np.array(ly); mx=lx.mean(); my=ly.mean()
    sxy=((lx-mx)*(ly-my)).sum(); sxx=((lx-mx)**2).sum()
    if sxx<=0.0: return 0.5
    return sxy/sxx

def MQL_Score(c,l1,l2,hTrend,hRevert,erDead,buyscore,sellscore,fade=False,
              hwin=256,erN=20):
    last=len(c)-1
    trend,roc=MQL_PrecisionTrend(c,l1,l2)
    v1=1 if trend[last]>0 else (-1 if trend[last]<0 else 0)
    v2=1 if roc[last]>0 else (-1 if roc[last]<0 else 0)
    H=MQL_Hurst(c,last,hwin); ER=MQL_EfficiencyRatio(c,last,erN)
    if H>hTrend: v3=v1
    elif fade and H<hRevert: v3=-v1
    else: v3=0
    score=v1+v2+v3
    d=0
    if ER>=erDead:
        if score>=buyscore: d=1
        elif score<=sellscore: d=-1
    return dict(v1=v1,v2=v2,v3=v3,score=score,dir=d,H=H,ER=ER)

# ---------- compare against the reference engine ----------
df=load_csv("eurusd-5m/EURUSD_5m.csv")
c=df.close.to_numpy(float)
print("bar count:",len(c))

# 1. HighPass3 agreement
for per in (150,24,250,40):
    a=MQL_HighPass3(c,per); b=highpass3(c,per)
    err=np.max(np.abs(a-b))
    print(f"  HighPass3 period={per:3d}  max|MQL-ref| = {err:.3e}  {'OK' if err<1e-12 else 'MISMATCH'}")

# 2. PrecisionTrend agreement
t1,r1=MQL_PrecisionTrend(c,150,24); t2,r2=precision_trend(c,150,24)
print(f"  PrecisionTrend        max|trend|={np.max(np.abs(t1-t2)):.3e}  max|roc|={np.max(np.abs(r1-r2)):.3e}")

# 3. EfficiencyRatio agreement
er_ref=efficiency_ratio(c,20)
diffs=[abs(MQL_EfficiencyRatio(c,i,20)-er_ref[i]) for i in range(300,len(c),997)]
print(f"  EfficiencyRatio       max|MQL-ref| = {max(diffs):.3e}")

# 4. Hurst agreement
hv=hurst_varscale(c,256)
diffs=[abs(MQL_Hurst(c,i,256)-hv[i]) for i in range(300,len(c),997) if np.isfinite(hv[i])]
print(f"  Hurst                 max|MQL-ref| = {max(diffs):.3e}  (mean {np.mean(diffs):.3e})")

# 5. score distribution using precomputed arrays (sampled)
trend,roc = MQL_PrecisionTrend(c,150,24)
er_ref = efficiency_ratio(c,20)
print("\n  computing Hurst at sampled indices ...")
idx=list(range(400,len(c),400))
Hs={i:MQL_Hurst(c,i,256) for i in idx}
scores=[]; dirs=[]; Hs_v=[]; ERs=[]
for i in idx:
    v1=1 if trend[i]>0 else (-1 if trend[i]<0 else 0)
    v2=1 if roc[i]>0 else (-1 if roc[i]<0 else 0)
    H=Hs[i]; ER=er_ref[i]
    v3 = v1 if H>0.55 else 0
    score=v1+v2+v3
    d=0
    if ER>=0.10:
        if score>=2: d=1
        elif score<=-2: d=-1
    scores.append(score); dirs.append(d); Hs_v.append(H); ERs.append(ER)
print("  score distribution:", {k:scores.count(k) for k in sorted(set(scores))})
print(f"  BUY {dirs.count(1)}  SELL {dirs.count(-1)}  HOLD {dirs.count(0)}  (of {len(dirs)} sampled bars)")
print(f"  H  range [{min(Hs_v):.3f}, {max(Hs_v):.3f}]  mean {np.mean(Hs_v):.3f}  frac>0.55 {np.mean([h>0.55 for h in Hs_v]):.3f}")
print(f"  ER mean {np.mean(ERs):.3f}  frac dead(<0.10) {np.mean([e<0.10 for e in ERs]):.3f}")
