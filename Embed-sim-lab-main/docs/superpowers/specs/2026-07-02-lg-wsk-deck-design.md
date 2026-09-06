# LG 후속 발표 덱 설계 — wsk_redesign 캠페인 보고 (2026-07-02, v2 간결판)

산출물: `slides/07.02_발표_자료.pptx` (표지 포함 11장, 부록 없음)
빌더: `slides/build_wsk_deck.py` → 미리보기 `bash slides/render.sh slides/07.02_발표_자료.pptx slides/preview_wsk`

## 중심 서사

6/19 서면 보고의 결론 "restore = I/O-bound, cold start = CPU-bound"는 당시엔 **주장**이었다.
이번 720런 캠페인은 그 명제를 **실험적으로 증명**하고(크기·연산량·CPU 부하 독립 sweep),
그 균형을 **pbs·nabs 적용 판별 규칙**으로 만들었다. 덱 전체가 이 3단 서사를 따른다:
주장(인용) → 증거(결과 2장) → 입증 선언 → 규칙 → 적용.

## 슬라이드 구성 (v2 — v1의 14장에서 압축)

1. 표지 (06.19 재사용, 날짜 2026. 07. 02 — 발표일에 맞게 수정)
2. 왜 이 실험인가 — 6/19 결론 인용 박스 + 목표 2개(실험적 검증 / 판별 기준 도출)
3. 실험 환경과 설계 — TV 앵커 표 + 설계 한 줄(720런) + 신규 통제 ◆ (v1의 환경/설계 2장 통합)
4. Workloads — 두 극단 카드 + TV 대응 예시 + 스펙트럼 그림("실제 앱 — pbs·nabs?")
5. 측정 정의와 공정성 — 타임라인 1회(창 안/밖) + ✓대칭 5개 + drop_caches 한계 (부록A 흡수)
6. Result ① memory-bound — fig2, "I/O-bound의 직접 증거" 프레임
7. Result ② compute-bound — fig1 + crossover 표, "CPU-bound의 직접 증거" 프레임
8. 검증 완료 — 명제별 증거 카드 2개 + "균형점이 존재·정량화" 선언
9. Decision Rule — 판별 공식 + 혼합형 역산 표
10. 적용 고려사항과 한계 — 운영 비용/한계 카드 + 안정성(720 PASS·OOM 0) (부록C 흡수)
11. Next Steps — pbs·nabs 절차 3단계 + Track A(RPi4)/B(디바이스 팜)

부록 삭제: A(공정성 표)→5장에 흡수, B(fig3)→fig1·2가 busy/idle×kdat을 이미 포함, C(수치 표)→결과 장이 대체.

## 스타일

06.19 pptx를 base로 표지만 남기고 재구성. ThemeLine(네이비 헤드라인), F2F5F7 카드,
teal-헤더 표, 네이비 ConclusionStrip + 골드(F2C75C) 강조. 결과 그림은
`testbed/experiments/wsk_redesign/figures/fig1·fig2` PNG 삽입.

## 수치 출처

`testbed/experiments/wsk_redesign/summary_by_condition.csv` (n=10/조건, bootstrap 95% CI).
crossover: idle·kOFF 150~200ms / busy·kOFF 100~150ms / idle·kON 50~100ms / busy·kON <50ms.
혼합형 역산 = restore(RSS)−cold_base(RSS), busy·kdat-ON: 30/40/50/60/70MB → ~180/190/260/360/370ms.
