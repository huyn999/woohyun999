# webos_probe — webOS 충실 라인 단위 checkpointability 실험

목표 서사를 실험 폴더 하나로 완결한다:

> **"webOS에서 실제로 일어나는 상황들을 라인 단위로 전수 측정했더니 통과했다.
> 남는 실패 요인들은 조사 결과 webOS가 쓰지 않는 것들이라 실전 문제가 아니며,
> 유일하게 실전에서 만나는 실패(연결 창·데몬화 순서)는 처방이 있다."**

## 폴더 구성

    gen_workloads_w.py     webOS 충실 워크로드 23종 생성기 (fp_w_*)
    run_webos_sweep.sh     원커맨드: 생성→빌드→스모크→스윕→리포트
    summarize_webos.py     비교 도출 리포트 (통과 지도 + 실패 태그 + 서사 문장)
    check_webos_usage.sh   "mq/SysV 미사용" 주장의 근거 수집 (rootfs·실기)

배치: Embed-sim-lab-main/ 아래에 failprobe/ 와 나란히 둔다 (failprobe의
gen_workloads.py·gen_workloads_v2.py·compat_sweep.sh 를 그대로 재사용).

## 설계 — 세 부류를 의도적으로 섞는다

| 부류 | 수 | 목적 |
|---|---|---|
| [P] 통과 예상군 | 18 | webOS OSE 아키텍처 문서의 컴포넌트(ls-hubd, SAM, WAM, JS서비스, DB8, tempdb, settings, memorymanager, notification, connman, bluetooth, audiod, uMedia, EPG, appinstalld, QML앱 ...)를 커널 객체로 번역. **"실재 상황은 얼려진다"의 입증층** |
| [R] 실패 재현군 | 4 | 기측정 실패요인의 webOS 맥락 재현 — enact_browser·media_hls(① tcp 창), sam_bad_order(② 순서, fp_w_sam과 한 성분 대조쌍), devmode_console(③ 개발자모드). **등급 판정의 입증층** |
| [U] 미지수 | 1 | registration — luna 등록 순간의 UNIX in-flight. **유일한 미측정 성분 = 신규 발견 후보** |

의도적으로 뺀 것: **④ mq, 레거시 SysV** — "webOS 충실"이라는 이름과 모순되므로
넣지 않는다. 대신 그 부재 주장을 check_webos_usage.sh 로 근거화하고, v1
커버리지 결과를 인용해 "쓴다면 이렇게 실패하고, 안 쓰므로 무해"로 대조한다.

## 기존 지침과의 정합

- 계약: workload.c + workload.yaml (contract v2), PHASE 라인 계측, KEEPFD 보유,
  die() 오염 차단, probe_server 기능 검증 — v1과 동일
- 환경: compat_sweep의 CONSTRAINED(1.71G/스왑0/4코어/stress 상주/dm-delay) ·
  PERMISSIVE 옵션 · PHASE_GAP_MS=150 · PHASE_TIMEOUT_S=40 — v1과 동일 기본값
- 명명: fp_w_* → 스윕 기본 glob(fp_*)과 호환, v1 데이터와 공존
- 하네스 위생: 셀별 잔재 즉시 정리(kill_cell 수정판) 전제. abstract UNIX 소켓
  사용으로 파일 잔재 자체를 만들지 않음

## 실행

    cd Embed-sim-lab-main
    DRY=1 webos_probe/run_webos_sweep.sh          # 생성·빌드·기동검증만 (수 분)
    sudo webos_probe/run_webos_sweep.sh           # 전체 (약 250셀, ~70분 추정)
    sudo RESUME=1 webos_probe/run_webos_sweep.sh  # 재개

리포트는 자동 출력되며, 수동 재실행은:

    python3 webos_probe/summarize_webos.py failprobe/results/compat_permissive_tv.csv

## 해석 가이드

- P군 전 통과 → 서사 1문장 확보. P군에서 실패가 나오면 그 자체가 발견(리포트가
  태그로 분류: 기존 4클러스터 재발 vs NEW)
- R군: 예상 지점(l05 / f_session / f_tty_l01)에서 예상 태그로 재발하는지 —
  재발하면 v1 발견의 webOS 프레임 재검증, 안 하면 조건 차이 분석 대상
- U군(registration): 실패(NEW) → "luna 등록 창" 신규 발견 / 통과 → "UNIX는
  TCP와 달리 등록 창이 안전"이라는 대비 발견. 어느 쪽이든 결과
- 마지막 칸은 실험 밖에서 닫는다: check_webos_usage.sh 를 OSE rootfs(정적
  심볼 스캔)와 실기(--live, 런타임 fd·ipcs)에 각각 돌려 "④·레거시 미사용"을
  증거 파일로 만든다. 발견되면 해당 클러스터를 C급에서 승격하고 재평가 —
  이 재평가 경로가 열려 있다는 것 자체가 주장의 정직성이다.

## 한계 (문서에 그대로 옮길 것)

- 배합은 OSE 공개 아키텍처 문서 기반의 번역이지 실측 지문이 아니다 — Tier 2
  (에뮬레이터에서 /proc fd·maps 지문 추출로 교정)가 후속 단계
- GPU/DRM·Wayland·HW디코더 성분은 데스크톱 환경 한계로 미포함 — WAM/브라우저
  워크로드는 그 성분을 제외한 부분 모델임을 명시할 것
