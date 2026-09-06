#!/usr/bin/env python3
"""crossover2 캠페인 그림 — 새 하네스(관측 슬랙 제거판)의 initburst crossover.
x = 실측 wl_compute_ms 중앙값(각 cpu에서 각자 실측 — 정직 라벨 원칙), 밴드 = bootstrap 95% CI.
figures → testbed/experiments/crossover2/figures/fig_crossover2.png
old(wsk_redesign) 수치와 같은 그래프에 겹치지 말 것 — PLAN.md §3 철칙(관측 슬랙)."""
import csv, os, statistics as st
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

EXP = "/root/Embed-sim-lab/testbed/experiments/crossover2"
FIG = os.path.join(EXP, "figures"); os.makedirs(FIG, exist_ok=True)
SUM = {r["condition"]: r for r in csv.DictReader(open(f"{EXP}/summary_by_condition.csv"))}
RUNS = list(csv.DictReader(open(f"{EXP}/all_runs.csv")))
NOM = [50, 100, 150, 200, 300, 500, 700]
C_COLD, C_ROFF, C_RON = "#2ca02c", "#d62728", "#1f77b4"

def med(cond, m):
    try: return float(SUM[cond][f"median_{m}_s"])
    except (KeyError, ValueError): return None
def ci(cond, m):
    try: return float(SUM[cond][f"{m}_s_ci_lo"]), float(SUM[cond][f"{m}_s_ci_hi"])
    except (KeyError, ValueError): return (None, None)
def mcompute(pfx):
    v = [float(r["wl_compute_ms"]) for r in RUNS
         if r["run_id"].startswith(pfx + "_rep") and r["runner"] == "cold"
         and r.get("wl_compute_ms", "na") not in ("na", "")]
    return st.median(v) if v else None

fig, ax = plt.subplots(1, 2, figsize=(13, 4.6), sharey=True)
for a, cpu, title in [(ax[0], "cpubusy", "CPU busy"), (ax[1], "cpuidle", "CPU idle")]:
    xs = [mcompute(f"crossover2_initburst_{n}_{cpu}") for n in NOM]
    for suf, m, col, mk, lab, ls in [
            ("", "cold_response", C_COLD, "o", "cold_response", "-"),
            ("_koff", "restore_response", C_ROFF, "s", "restore_response (kdat off)", "--"),
            ("_kon", "restore_response", C_RON, "^", "restore_response (kdat on)", "-")]:
        conds = [f"crossover2_initburst_{n}_{cpu}{suf}" for n in NOM]
        ys = [med(c, m) for c in conds]
        lo = [ci(c, m)[0] for c in conds]; hi = [ci(c, m)[1] for c in conds]
        a.plot(xs, ys, marker=mk, color=col, ls=ls, lw=2, ms=7, label=lab, zorder=3)
        if all(v is not None for v in lo):
            a.fill_between(xs, lo, hi, color=col, alpha=0.14, zorder=1)
    a.set_title(title); a.set_xlabel("measured compute_ms (median)")
    a.grid(True, alpha=0.3); a.legend(fontsize=9, loc="upper left")
ax[0].set_ylabel("first-response (s, median; band=bootstrap 95% CI)")
fig.suptitle("crossover2: initburst sweep, artifact-free harness (n=10/point) — "
             "crossover: busy koff≈184ms / idle koff≈112ms / kon: below lowest point", fontsize=12)
fig.tight_layout(rect=[0, 0, 1, 0.95])
fig.savefig(f"{FIG}/fig_crossover2.png", dpi=120)
print("wrote:", f"{FIG}/fig_crossover2.png")
