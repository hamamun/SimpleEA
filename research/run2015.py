import numpy as np, pandas as pd
from engine import precision_trend, efficiency_ratio, hurst_dfa, atr
from validate import fwd_ret, PIP
import run3 as R3

def load2015(path):
    df=pd.read_csv(path,sep=";",header=None,names=["ts","open","high","low","close","volume"])
    df["dt"]=pd.to_datetime(df["ts"],format="%Y%m%d %H%M%S")
    return df[["dt","open","high","low","close","volume"]].sort_values("dt").reset_index(drop=True)

def resample(df,rule):
    d=df.set_index("dt")
    return d.resample(rule).agg({"open":"first","high":"max","low":"min","close":"last"}).dropna().reset_index().rename(columns={"dt":"datetime"})

df1=load2015("/tmp/old/EURUSD_2015.csv")
print("M1 bars:",len(df1), df1.dt.iloc[0],"->",df1.dt.iloc[-1])
out=[]
for tf,rule,hz in (("M5","5min",(6,12,24)),("M15","15min",(4,8,16)),("M30","30min",(4,8,16))):
    d=resample(df1,rule)
    print(f"  {tf}: {len(d)} bars")
    m=len(d)//2
    for half,d2 in (("IS",d.iloc[:m]),("OOS",d.iloc[m:])):
        out.append(R3.report(d2.reset_index(drop=True),"EURUSD",tf,half,hz,
            l1=150,l2=24,er_n=20,er_lo=0.30,er_hi=0.25,h_th=0.52,h_lo=0.47))
res=pd.concat(out,ignore_index=True)
res.to_csv("/tmp/fxdata/run2015_out.csv",index=False)
pd.set_option("display.width",300); pd.set_option("display.max_rows",900)
piv=res.pivot_table(index=["tf","h","rule"],columns="half",values=["pips","hit","p"],sort=False)
print("\n##### EURUSD 2015 (independent era) #####")
print(piv.to_string())
