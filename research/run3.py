import numpy as np, pandas as pd
from engine import precision_trend, efficiency_ratio, hurst_dfa, atr, load_csv
from validate import fwd_ret, PIP

RNG = np.random.default_rng(7)

def mc_pvalue(d, r, nsim=2000):
    """Null: identical long/short mix but directions assigned at random.
    Preserves the return distribution (hence any sample drift) and asks only
    whether the *timing* of the directions carries information."""
    n=len(r); nlong=int((d>0).sum()); nshort=int((d<0).sum())
    obs=float((d*r).sum()); null=np.empty(nsim)
    for k in range(nsim):
        pos=np.zeros(n); idx=RNG.permutation(n)
        pos[idx[:nlong]]=1.0; pos[idx[nlong:nlong+nshort]]=-1.0
        null[k]=float((pos*r).sum())
    p=float((np.abs(null)>=abs(obs)).mean())
    return obs,p,float(null.std())

def build_rules(df,l1,l2,er_n,er_lo,er_hi,h_th,h_lo,hurst_w=256):
    close=df["close"].to_numpy(float); high=df["high"].to_numpy(float); low=df["low"].to_numpy(float)
    trend,roc=precision_trend(close,l1,l2)
    er=efficiency_ratio(close,er_n); H=hurst_dfa(close,hurst_w); a=atr(high,low,close,14)
    base=np.where((trend>0)&(roc>0),1,np.where((trend<0)&(roc<0),-1,0))
    ok=np.isfinite(er)&np.isfinite(H)&np.isfinite(a)
    R={}
    R["R1 trend"]              =np.where(ok,base,0)
    R["R2 trend ER>.30"]       =np.where(ok&(er>er_lo),base,0)
    R["R3 trend H>.52"]        =np.where(ok&(H>h_th),base,0)
    R["R4 fade H<.47"]         =np.where(ok&(H<h_lo),-base,0)
    R["R5 fade ER<.25"]        =np.where(ok&(er<er_hi),-base,0)
    R["R6 trend H>.52 ER>.30"] =np.where(ok&(H>h_th)&(er>er_lo),base,0)
    R["R7 ADAPTIVE"]           =np.where(ok,np.where(H>h_th,base,np.where(H<h_lo,-base,0)),0)
    return R,a

def report(df,sym,tf,half,horizons,**kw):
    R,a=build_rules(df,**kw); close=df["close"].to_numpy(float); n=len(close)
    rows=[]
    for name,sig in R.items():
        for h in horizons:
            fr=fwd_ret(close,h); valid=np.isfinite(fr)&(sig!=0)
            if valid.sum()<60: continue
            d=sig[valid].astype(float); r=fr[valid]
            obs,p,tz=mc_pvalue(d,r)
            pipv=PIP[sym]; npips=len(r)
            rows.append(dict(sym=sym,tf=tf,half=half,rule=name,h=h,n=int(valid.sum()),
                cover=round(valid.sum()/n,2),hit=round(float((np.sign(r)==d).mean()),4),
                pips=round(obs/pipv/npips,3),p=round(p,3),tz=round(tz,2)))
    return pd.DataFrame(rows)

def resample(df,mult):
    d=df.set_index("datetime")
    return d.resample(f"{mult*5}min").agg({"open":"first","high":"max","low":"min","close":"last","volume":"sum"}).dropna().reset_index()

data=[("EURUSD","M5","eurusd-5m/EURUSD_5m.csv",1),
      ("GBPUSD","M5","gbpusd-5m/GBPUSD_5m.csv",1),
      ("USDJPY","M5","usdjpy-5m/USDJPY_5m.csv",1),
      ("EURUSD","M15","eurusd-15m/EURUSD_15m.csv",1),
      ("XAUUSD","M15","xauusd-15m/XAUUSD_15m.csv",1),
      ("EURUSD","M30","eurusd-30m/EURUSD_30m.csv",1),
      ("XAUUSD","M30","xauusd-15m/XAUUSD_15m.csv",2)]
HZ={"M5":(6,12,24),"M15":(4,8,16),"M30":(4,8,16)}
out=[]
for sym,tf,path,mult in data:
    df=load_csv(path)
    if mult>1: df=resample(df,mult)
    m=len(df)//2
    for half,d2 in (("IS",df.iloc[:m]),("OOS",df.iloc[m:])):
        out.append(report(d2.reset_index(drop=True),sym,tf,half,HZ[tf],
                          l1=150,l2=24,er_n=20,er_lo=0.30,er_hi=0.25,h_th=0.52,h_lo=0.47))
res=pd.concat(out,ignore_index=True)
res.to_csv("/tmp/fxdata/run3_out.csv",index=False)
pd.set_option("display.width",300); pd.set_option("display.max_rows",900)
print("\n##### MEAN PIPS PER TRADE (IS | OOS) and MC p-value #####")
piv=res.pivot_table(index=["sym","tf","h","rule"],columns="half",values=["pips","hit","p"],sort=False)
print(piv.to_string())
