# xmatrix.sh — 봉쇄 조건 행렬 (구 criu_x.sh xmatrix)

"연결이 dump/restore 를 넘는가"를 **리스너/커넥터 위상**별로 가른다. `gen_workloads_x.py` 가
`fp_x_*` 6종을 `testbed/workloads/` 아래에 생성하고, 셀마다 `xpeer`(덤프 밖 상대)를 띄운 뒤
dump→restore→verify 를 돌려 CSV 로 남긴다.

## 6종 (두 전송 × 세 봉쇄)

| 워크로드 | 위상 |
|---|---|
| `fp_x_backlog_{unix,tcp}` | 리스너=나, 커넥터=자식(둘 다 덤프 안), 미accept |
| `fp_x_ext_{unix,tcp}_pend` | 리스너=외부 xpeer(덤프 밖), 미accept = 실전 등록/수립 창 |
| `fp_x_ext_{unix,tcp}_est` | 외부 xpeer 와 성립 완료 = 대조군 |

```bash
sudo ./xmatrix.sh
```

산출: `results/compat_xmatrix.csv` (workload,phase,dump_rc,restore_rc,verify,…) + 셀별
`results/runs/<wl>__<phase>__xmatrix/`.

## 원본과의 차이

자기 압축 해제형이던 criu_x.sh 는 `xpeer.c`·`gen_workloads_x.py` 를 실행 중 `webos_probe/` 에
풀어놓았다(그 부산물이 기존 패키지를 오염시켰다). 이제 두 소스는 이 패키지에 파일로 있고,
`xpeer` 는 `build.sh` 가 미리 빌드한다. 전제: `testbed/workloads/build.sh` 로 fp_x_* 빌드
(스크립트가 자동 호출), `testbed/criu` 빌드 완료.
