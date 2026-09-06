#!/usr/bin/env python3
# pbsprobe/gen_lbl.py — 줄 단위 계측 변환기
#
# pbs_mock의 main() 생애주기(시작~ready)에서 "순차 실행이 보장되는 모든 문장"
# 뒤에 PHASE("Lsrc_<seq> ln=<원본줄>") + gap 을 자동 삽입한 변형 워크로드
# testbed/workloads/pbs_mock_lbl/ 을 생성한다. 결과: 소스 줄 하나 = dump 지점 하나.
#
# 삽입 규칙 (보수적 — 컴파일 안전 우선):
#  · main() 본문, PHASE ready port") 이전 구간만
#  · 탭 1개 깊이(=main 직속, 무조건 실행되는 순차 문장)에서 ';'로 끝나는 줄
#  · 제외: 선언만 있는 case/break/continue/return/goto, 이미 PHASE/phase_gap 줄,
#    for/while/if/else 헤더, 여는/닫는 중괄호 줄, 다줄 문장의 중간(끝이 ';' 아님)
#  · 루프 내부(탭2+)는 삽입 안 함 — 그 구간은 본편의 per-자원 phase와
#    substeps(25/50/75%)가 담당
# 산출: workload.c(변형) + workload.yaml + pbsprobe/lbl_phases.txt (phase 목록)
import os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "testbed/workloads/pbs_mock/workload.c")
DSTD = os.path.join(ROOT, "testbed/workloads/pbs_mock_lbl")
PHLIST = os.path.join(ROOT, "pbsprobe/lbl_phases.txt")

src = open(SRC).read().splitlines(keepends=False)

# main() 본문 범위: "int main" 다음 줄부터 PHASE ready port 줄 전까지
mstart = next(i for i, l in enumerate(src) if l.startswith("int main"))
gline = next(i for i, l in enumerate(src) if "long gap_ms" in l and "wl_flag_long" in l)
rline = next(i for i, l in enumerate(src) if 'PHASE ready port' in l)

SKIP_PAT = re.compile(r"^\s*(PHASE|phase_gap|break;|continue;|return|goto|case |default:|\}|\{|for\s*\(|while\s*\(|if\s*\(|else)")
out, names, seq = [], [], 0
for i, l in enumerate(src):
    out.append(l)
    if not (gline < i < rline):
        continue
    if not (l.startswith("\t") and not l.startswith("\t\t")):
        continue                                  # main 직속(탭1)만
    s = l.strip()
    if not s.endswith(";"):
        continue                                  # 다줄 문장/헤더 제외
    if SKIP_PAT.match(s):
        continue
    seq += 1
    name = f"Lsrc_{seq:03d}"
    names.append((name, i + 1, s[:60]))
    out.append(f'\tif (lbl_trace) {{ PHASE("{name} ln={i+1}"); phase_gap(gap_ms); }}')

# lbl_trace 플래그 선언 삽입 (gap_ms 파싱 직후) — gap_ms 선언 줄 탐색
txt = "\n".join(out)
anchor = re.search(r'\tlong gap_ms\s*=\s*wl_flag_long\([^\n]*\n', txt)
if not anchor:
    print("ERROR: gap_ms 앵커 없음"); sys.exit(1)
txt = txt[:anchor.end()] + \
    '\tlong lbl_trace   = wl_flag_long(argc, argv, "--lbl", 0);          /* 줄 단위 계측 (자동 생성판) */\n' + \
    txt[anchor.end():]

os.makedirs(DSTD, exist_ok=True)
open(os.path.join(DSTD, "workload.c"), "w").write(txt + "\n")
# manifest: 원본 복사 + lbl phase 목록 추가
y = open(os.path.join(ROOT, "testbed/workloads/pbs_mock/workload.yaml")).read()
y = y.replace("name: pbs_mock", "name: pbs_mock_lbl") if "name:" in y else y
y += "\n# 줄 단위 phase (자동 생성)\n" + "".join(f"#  - {n}\n" for n, _, _ in names)
open(os.path.join(DSTD, "workload.yaml"), "w").write(y)
open(PHLIST, "w").write("".join(f"{n}\t{ln}\t{stmt}\n" for n, ln, stmt in names))
print(f"[gen_lbl] 문장 {seq}개 계측 → {DSTD} + {PHLIST}")
