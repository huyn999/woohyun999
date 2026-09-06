# capture.sh — 세 실패 상황 캡처용 정렬 출력 (구 criu_cap.sh)

발표/문서용. 실패(와 통과) 상황을 "관측 지점" 형식으로 화면에 정렬해 보여준다. 새 측정을
하기보다, 이미 아는 현상을 **재현 가능한 캡처**로 만든다.

```bash
sudo ./capture.sh hub-ok     # ①-A 허브를 함께 얼림 → 통과 (소켓·큐·JSON 전부 복원)
sudo ./capture.sh hub        # ①-B 허브가 경계 밖 → CRIU 거부
sudo ./capture.sh tcp        # ②   TCP 클라이언트 → 거부 안 함 (대조군)
sudo ./capture.sh mem-heavy  # ③-a 무거운 이미지 → 복원 거부 (정직한 실패)
sudo ./capture.sh mem-light  # ③-b 가벼운 이미지 → rc=0·에러0 인데 5초 뒤 OOM 사망 (침묵형 ★)
sudo ./capture.sh all        # 다섯 상황 전부
```

## 의존

- `xpeer` — 이 패키지 `bin/xpeer` (`XPEER` 환경변수로 재지정 가능).
- `fp_w_hub`, `fp_x_ext_unix_{est,pend}`, `fp_x_ext_tcp_pend`, `fp_w_qml_app` — failprobe/
  webos_probe 워크로드. `xmatrix.sh`(fp_x_*)와 `webos_probe/run_webos_sweep.sh` 또는
  `testbed/workloads/build.sh`(fp_w_*)로 먼저 빌드돼 있어야 한다. 없으면 해당 항목 `[skip]`.

## 원본과의 차이

ROOT 를 repo 루트로 재계산하고, `xpeer` 를 `testbed/workloads/bin` 대신 `connprobe/bin` 에서
찾도록 한 것 외에는 criu_cap.sh 와 동일 로직.
