#!/usr/bin/env python3
"""wsk_redesign 캠페인 그림 (harness 수정판). reports/에 두어 재실험 rm에 안 지워짐.
figures → testbed/experiments/wsk_redesign/figures/
  fig1_initburst_crossover.png  fig2_dirty_sweep.png  fig3_kdat_and_cpu_bars.png"""
import csv, os, statistics as st
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

EXP="/root/Embed-sim-lab/testbed/experiments/wsk_redesign"
FIGDIR=os.path.join(EXP,"figures"); os.makedirs(FIGDIR,exist_ok=True)
SUM={r["condition"]:r for r in csv.DictReader(open(os.path.join(EXP,"summary_by_condition.csv")))}
RUNS=list(csv.DictReader(open(os.path.join(EXP,"all_runs.csv"))))
C_COLD="#2ca02c"; C_ROFF="#d62728"; C_RON="#1f77b4"

def med(c,m):
    try: return float(SUM[c][f"median_{m}_s"])
    except: return None
def ci(c,m):
    try: return float(SUM[c][f"{m}_s_ci_lo"]), float(SUM[c][f"{m}_s_ci_hi"])
    except: return (None,None)
def mcompute(pfx):
    v=[float(r["compute_ms"]) for r in RUNS if r["run_id"].startswith(pfx+"_") and r["runner"]=="cold"
       and r.get("compute_ms","na") not in("na","NA","")]
    return st.median(v) if v else None
def band(ax,xs,ys,lo,hi,color,marker,label,ls="-"):
    ax.plot(xs,ys,marker=marker,color=color,ls=ls,lw=2,ms=7,label=label,zorder=3)
    if all(v is not None for v in lo): ax.fill_between(xs,lo,hi,color=color,alpha=0.14,zorder=1)

# fig1 initburst crossover
IB=[50,100,150,200,300,500,700]
fig,ax=plt.subplots(1,2,figsize=(13,4.6),sharey=True)
for a,cpu,t in [(ax[0],"cpubusy","CPU busy"),(ax[1],"cpuidle","CPU idle")]:
    xs=[mcompute(f"ib_{ms}ms_{cpu}") for ms in IB]
    for suf,mm,col,mk,lab,ls in [("","cold_response",C_COLD,"o","cold_response","-"),
                                 ("_koff","restore_response",C_ROFF,"s","restore_response (kdat off)","--"),
                                 ("_kon","restore_response",C_RON,"^","restore_response (kdat on)","-")]:
        ys=[med(f"ib_{ms}ms_{cpu}{suf}",mm) for ms in IB]
        lo=[ci(f"ib_{ms}ms_{cpu}{suf}",mm)[0] for ms in IB]; hi=[ci(f"ib_{ms}ms_{cpu}{suf}",mm)[1] for ms in IB]
        band(a,xs,ys,lo,hi,col,mk,lab,ls)
    a.set_title(t); a.set_xlabel("measured compute_ms (median)"); a.grid(True,alpha=0.3); a.legend(fontsize=9,loc="upper left")
ax[0].set_ylabel("first-response (s, median; band=bootstrap 95% CI)")
fig.suptitle("workload-initburst sweep: measured compute_ms vs cold/restore response (n=10/point)",fontsize=13)
fig.tight_layout(rect=[0,0,1,0.96]); fig.savefig(f"{FIGDIR}/fig1_initburst_crossover.png",dpi=120); plt.close(fig)

# fig2 dirty sweep
D=[30,40,50,60,70]
fig,ax=plt.subplots(1,2,figsize=(13,4.6),sharey=True)
for a,cpu,t in [(ax[0],"cpubusy","CPU busy"),(ax[1],"cpuidle","CPU idle")]:
    for suf,mm,col,mk,lab,ls in [("","cold_response",C_COLD,"o","cold_response","-"),
                                 ("_koff","restore_response",C_ROFF,"s","restore_response (kdat off)","--"),
                                 ("_kon","restore_response",C_RON,"^","restore_response (kdat on)","-")]:
        ys=[med(f"dirty_{s}M_{cpu}{suf}",mm) for s in D]
        lo=[ci(f"dirty_{s}M_{cpu}{suf}",mm)[0] for s in D]; hi=[ci(f"dirty_{s}M_{cpu}{suf}",mm)[1] for s in D]
        band(a,D,ys,lo,hi,col,mk,lab,ls)
    a.set_title(t); a.set_xlabel("workload-dirty size (MiB)"); a.grid(True,alpha=0.3); a.legend(fontsize=9,loc="upper left")
ax[0].set_ylabel("first-response (s, median; band=bootstrap 95% CI)")
fig.suptitle("workload-dirty sweep: memory footprint vs cold/restore response (n=10/point)",fontsize=13)
fig.tight_layout(rect=[0,0,1,0.96]); fig.savefig(f"{FIGDIR}/fig2_dirty_sweep.png",dpi=120); plt.close(fig)

# fig3 busy/idle + kdat bars
reps=[("ib_700ms","initburst-hi (488 iters)"),("dirty_70M","dirty-70MiB")]
fig,ax=plt.subplots(1,2,figsize=(13,4.6))
groups=["cold","restore\n(kdat off)","restore\n(kdat on)"]; xpos=range(3); w=0.35
for a,(pfx,t) in zip(ax,reps):
    def vals(cpu): return [med(f"{pfx}_{cpu}","cold_response"),med(f"{pfx}_{cpu}_koff","restore_response"),med(f"{pfx}_{cpu}_kon","restore_response")]
    def errs(cpu):
        out=[]
        for c,m in [(f"{pfx}_{cpu}","cold_response"),(f"{pfx}_{cpu}_koff","restore_response"),(f"{pfx}_{cpu}_kon","restore_response")]:
            v=med(c,m); lo,hi=ci(c,m); out.append((v-lo,hi-v) if lo is not None else (0,0))
        return list(zip(*out))
    cols=[C_COLD,C_ROFF,C_RON]
    for i,cpu,hatch in [(0,"cpubusy",None),(1,"cpuidle","//")]:
        a.bar([x+(i-0.5)*w for x in xpos],vals(cpu),w,color=cols,edgecolor="black",hatch=hatch,yerr=errs(cpu),capsize=3)
    a.set_xticks(list(xpos)); a.set_xticklabels(groups); a.set_title(t); a.grid(True,axis="y",alpha=0.3)
    a.set_ylabel("first-response (s, median; bar=95% CI)")
leg=[Patch(facecolor="0.7",edgecolor="black",label="CPU busy (solid)"),Patch(facecolor="0.7",edgecolor="black",hatch="//",label="CPU idle (hatched)")]
ax[0].legend(handles=leg,fontsize=9,loc="upper right")
fig.suptitle("stress-CPU busy vs idle, kdat on vs off — representative workloads (n=10/bar)",fontsize=13)
fig.tight_layout(rect=[0,0,1,0.96]); fig.savefig(f"{FIGDIR}/fig3_kdat_and_cpu_bars.png",dpi=120); plt.close(fig)
print("wrote:",sorted(os.listdir(FIGDIR)))
