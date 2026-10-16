import numpy as np, pandas as pd
from engine import hurst_dfa, efficiency_ratio, load_csv

def hurst_varscale(close,w=256,scales=(1,2,4,8,16)):
    """Cheap 2-N point estimator: std of n-bar aggregated returns scales as n^H."""
    n=len(close); out=np.full(n,np.nan)
    lr=np.zeros(n); lr[1:]=np.log(close[1:]/close[:-1])
    ls=np.log(np.array(scales,float))
    for i in range(w,n):
        x=lr[i-w+1:i+1]; x=x[np.isfinite(x)]
        if len(x)<w: continue
        st=[]
        for s in scales:
            k=len(x)//s
            if k<4: st.append(np.nan); continue
            agg=x[:k*s].reshape(k,s).sum(axis=1)
            st.append(agg.std(ddof=1))
        st=np.array(st)
        ok=np.isfinite(st)&(st>0)
        if ok.sum()>=3: out[i]=np.polyfit(ls[ok],np.log(st[ok]),1)[0]
    return out

def hurst_frama(high,low,w=256):
    """Ehlers fractal dimension from FRAMA, converted H = 2 - D. Cheap: highs/lows only."""
    n=len(high); D=np.full(n,np.nan)
    for i in range(w,n):
        def rng(a,b): return np.max(a[b])-np.min(a[b])
        # use the DFA window as the FRAMA window
        N=w//4
        seg=slice(i-N+1,i+1); seg2=slice(i-N//2+1,i+1)
        seg3=slice(i-N+1,i-N//2+1)
        N1=(rng(high,seg)-rng(low,seg))/N
        N2=(rng(high,seg2)-rng(low,seg2))/(N//2)
        N3=(rng(high,seg3)-rng(low,seg3))/(N//2)
        if min(N1,N2,N3)<=0: continue
        D[i]=(np.log(N1+N2)-np.log(N3))/np.log(2)
    return 2.0-D

for tf,p in (("M5","eurusd-5m/EURUSD_5m.csv"),("M15","eurusd-15m/EURUSD_15m.csv"),("M30","eurusd-30m/EURUSD_30m.csv")):
    df=load_csv(p)
    c=df.close.to_numpy(float); h=df.high.to_numpy(float); l=df.low.to_numpy(float)
    hd=hurst_dfa(c,256); hv=hurst_varscale(c,256); hf=hurst_frama(h,l,256)
    er=efficiency_ratio(c,20)
    m=np.isfinite(hd)&np.isfinite(hv)&np.isfinite(hf)
    print(f"\n=== EURUSD {tf}  (n={m.sum()}) ===")
    print(f"  DFA   H: mean {np.nanmean(hd):.3f} std {np.nanstd(hd):.3f} pct[10,50,90]={np.nanpercentile(hd[m],[10,50,90]).round(3)}")
    print(f"  varSc H: mean {np.nanmean(hv):.3f} std {np.nanstd(hv):.3f} pct[10,50,90]={np.nanpercentile(hv[m],[10,50,90]).round(3)}")
    print(f"  FRAMA H: mean {np.nanmean(hf):.3f} std {np.nanstd(hf):.3f} pct[10,50,90]={np.nanpercentile(hf[m],[10,50,90]).round(3)}")
    print(f"  corr(DFA,varSc)={np.corrcoef(hd[m],hv[m])[0,1]:.3f}  corr(DFA,FRAMA)={np.corrcoef(hd[m],hf[m])[0,1]:.3f}  corr(varSc,FRAMA)={np.corrcoef(hv[m],hf[m])[0,1]:.3f}")
    print(f"  ret autocorr lag1={pd.Series(np.diff(np.log(c))).autocorr(1):.4f}")
    v=er[np.isfinite(er)]
    print(f"  ER(20) pct[10,25,50,75,90]={np.percentile(v,[10,25,50,75,90]).round(3)}")
    print(f"  frac of bars ER<0.25 {np.mean(v<0.25):.2f}  ER<0.30 {np.mean(v<0.30):.2f}  ER>0.30 {np.mean(v>0.30):.2f}  ER>0.40 {np.mean(v>0.40):.2f}")
