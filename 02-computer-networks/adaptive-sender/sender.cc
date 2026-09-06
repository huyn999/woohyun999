#include "netsim.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <cmath>
#include <algorithm>


static uint32_t crc_lookup[256];//8비트 연산을 crc에서 한번에 처리

static void build_crc_lookup()
{
    const uint32_t kGenPoly = 0x04C11DB7u;

    for (int b = 0; b < 256; ++b) {
        uint32_t c = (uint32_t)b << 24;

        for (int i = 0; i < 8; ++i) {
            // MSB가 1이면 시프트 후 generator 와 XOR (modulo-2 빼기)
            // MSB가 0이면 그냥 시프트
            c = (c & 0x80000000u) ? ((c << 1) ^ kGenPoly) : (c << 1);
        }
        crc_lookup[b] = c;
    }
}

// 각 byte 마다 idx = (register 상위 8비트) XOR (입력 byte)
// register = (register << 8) XOR crc_lookup[idx]
static uint32_t compute_crc32(const uint8_t* data, size_t len) {
    uint32_t crc = 0;
    for (size_t i = 0; i < len; ++i) {
        uint8_t idx = (uint8_t)(((crc >> 24) ^ (uint32_t)data[i]) & 0xFFu);
        crc = (crc << 8) ^ crc_lookup[idx];
    }
    return crc;
}


//    OVERHEAD : 프레임의 size(2B) + CRC(4B) = 6
//    K_COST   : RTT 한 번에 해당하는 byte 수 
//    A_CONST  : 고정 비용 = OVERHEAD + K_COST = 256
//    P_MIN/MAX: payload 크기 범위 


static constexpr int OVERHEAD = 6;
static constexpr int K_COST   = 250;
static constexpr int A_CONST  = OVERHEAD + K_COST;
static constexpr int P_MIN    = 4;
static constexpr int P_MAX    = 65535;

/* BerGrid — 격자 기반 BER 사후 분포 추정기
log10 스케일 격자에 BER 후보 70개를 두고, 매 frame ACK/NAK 관측을
 각 후보의 log-likelihood 에 누적한다 (Bayesian update).
  한 frame 성공 확률  q = (1 - BER)^(8 * (P + 4))
  추정값: 사후 분포에 대한 log10(BER) 가중 평균 → 10^x 로 환원
          (= 기하 평균 BMA, Bayesian Model Averaging)
   prior 는 Laplace (heavy-tailed): log p(x) ∝ -|x - μ| / b 로 설정
   추정값은 가중 평균으로 구함
*/

struct BerGrid {
    static constexpr int    GRID_N      = 70;     // 후보 개수
    static constexpr double GRID_LO     = -7.0;   // log10(BER) 하한
    static constexpr double GRID_STEP   = 0.085;  // 격자 간격

    // Laplace prior 파라미터 — BER 약 1.58e-4 근처가 가장 그럴듯하다고 가정
    static constexpr double PRIOR_MU    = -3.8;
    static constexpr double PRIOR_SCALE = 1.2;    

    double cand_log10[GRID_N];   // 각 후보의 log10(BER) 값
    double cand_ber[GRID_N];     // 각 후보의 BER 값
    double log_qbit[GRID_N];     // log(1 - BER_i) 미리 계산
    double log_post[GRID_N];     // 누적 log 사후 

    BerGrid() {
        for (int i = 0; i < GRID_N; ++i) {
            double lb = GRID_LO + GRID_STEP * i;
            cand_log10[i] = lb;
            cand_ber[i]   = std::pow(10.0, lb);

            // log(1-BER_i) 미리 계산 매 frame likelihood 갱신을 간편화
            double one_minus = 1.0 - cand_ber[i];
            if (one_minus < 1e-300) one_minus = 1e-300;
            log_qbit[i] = std::log(one_minus);

            // Laplace log prior
            log_post[i] = -std::fabs(lb - PRIOR_MU) / PRIOR_SCALE;
        }
    }

    // 한 frame 의 결과(ACK/NAK)를 사후 분포에 반영
    void observe(int payload, bool was_ack) {
        const double exposed = 8.0 * (double)(payload + 4);

        for (int i = 0; i < GRID_N; ++i) {
            double log_ack = exposed * log_qbit[i];
            if (log_ack > 0.0) log_ack = 0.0;

            if (was_ack) {
                log_post[i] += log_ack;
            } else {
                double ack_prob = std::exp(log_ack);
                if (ack_prob >= 1.0 - 1e-15) {
                    // BER 이 매우 작아 exp(log_ack) ≈ 1 인 경우 
                    log_post[i] += std::log(1e-15);
                } else {
                    // log1p(-q) = log(1 - q), q 가 작을 때 안정적임
                    log_post[i] += std::log1p(-ack_prob);
                }
            }
        }
    }

    // 사후 분포의 점추정값을 기하 평균 BMA로 추정
    double estimate_ber() const {
        double max_lp = log_post[0];
        for (int i = 1; i < GRID_N; ++i)
            if (log_post[i] > max_lp) max_lp = log_post[i];

        double Z = 0.0;
        double sum_log = 0.0;
        for (int i = 0; i < GRID_N; ++i) {
            double w = std::exp(log_post[i] - max_lp);
            Z       += w;
            sum_log += w * cand_log10[i];
        }
        return std::pow(10.0, sum_log / Z);
    }
};


static int compute_optimal_payload(double p) { //최적 페이로드 크기 계산 (추정한 ber 적용)
    if (p <= 0.0) return P_MAX;
    double q = -std::log(1.0 - p);
    if (q <= 0.0) return P_MAX;

    double A = (double)A_CONST;
    double rad  = A * A + A / (2.0 * q);
    double Popt = (std::sqrt(rad) - A) / 2.0;

    if (Popt < (double)P_MIN) Popt = (double)P_MIN;
    if (Popt > (double)P_MAX) Popt = (double)P_MAX;

    return (int)Popt;
}

// 단일 frame 의 기대 cost (마지막 청크 의사결정에서 두 옵션 비교용)
//   cost = (P + 256) / (1 - BER)^(8(P+4))
static double single_frame_cost(int payload, double ber) {
    double q = std::pow(1.0 - ber, 8.0 * (double)(payload + 4));
    if (q < 1e-12) q = 1e-12;
    return (double)(payload + A_CONST) / q;
}



//  PayloadAdapter ber 추정값은 매 frame 마다 noisy 하므로 즉시 점프하면 흔들림이 큼 따라서 adapter 사용

struct PayloadAdapter {
    double smoothed_target = 2048.0;  
    bool   has_obs = false;

    // 새 BER 추정에서 나온 P_target 을 EWMA 로 부드럽게 흡수
    void update_target(int new_target) {
        if (!has_obs) {
            smoothed_target = (double)new_target;
            has_obs = true;
        } else {
            constexpr double ALPHA = 0.35;
            smoothed_target = ALPHA * new_target + (1.0 - ALPHA) * smoothed_target;
        }
    }

    // ACK 후 P 결정 
    //   target > current 면: step = current/2 만큼만 증가
    //   target < current 면: 10% 씩만 감소 
    int on_ack(int current_P) {
        int target = (int)smoothed_target;
        int new_P;
        if (current_P < target) {
            int step = std::max(current_P / 2, 1);
            new_P = std::min(current_P + step, target);
        } else {
            int step = std::max(current_P / 10, 1);
            new_P = std::max(current_P - step, target);
        }
        if (new_P < P_MIN) new_P = P_MIN;
        if (new_P > P_MAX) new_P = P_MAX;
        return new_P;
    }

    // NAK 후 P 결정 
    //   half = current/2 로 절반으로 줄이되, target 이 더 크면 그쪽으로는 가지 않음
    int on_nak(int current_P) {
        int target = (int)smoothed_target;
        int half   = current_P / 2;
        int new_P  = std::max(half, std::min(target, current_P));
        if (new_P < P_MIN) new_P = P_MIN;
        if (new_P > P_MAX) new_P = P_MAX;
        return new_P;
    }
};

//  Main 송신 루프


int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <input_file>\n", argv[0]);
        return 1;
    }

    build_crc_lookup();// crc 테이블 생성 

    //  입력 파일 로드
    std::FILE* fp = std::fopen(argv[1], "rb");
    if (!fp) {
        std::fprintf(stderr, "cannot open: %s\n", argv[1]);
        return 1;
    }

    std::fseek(fp, 0, SEEK_END);
    long fsize_l = std::ftell(fp);
    std::fseek(fp, 0, SEEK_SET);

    if (fsize_l < 0)  { std::fclose(fp); return 1; }
    if (fsize_l == 0) { std::fclose(fp); return 0; }  // 빈 파일

    size_t fsize = (size_t)fsize_l;
    std::vector<uint8_t> data(fsize);

    if (std::fread(data.data(), 1, fsize, fp) != fsize) {
        std::fclose(fp);
        std::fprintf(stderr, "read failed\n");
        return 1;
    }
    std::fclose(fp);

    //  상태 객체 초기화 
    std::vector<uint8_t> frame(OVERHEAD + P_MAX);
    BerGrid        stats;
    PayloadAdapter sizer;

    // 적응적 P_INIT 
    //   파일 크기에 따라 초기 payload 크기를 다르게.
    //   작은 파일: 큰 P 로 시작하면 cold start NAK 손해 비중 큼
    //   큰 파일:   작게 시작하면 P_target 까지 ramp-up 하는 frame 이 낭비
    int P;
    if      (fsize < 400000)   P = 384;
    else if (fsize < 1500000)  P = 1280;
    else                       P = 3200;

    size_t pos = 0;

    // 메인 송신 루프 
    while (pos < fsize) {
        size_t remaining = fsize - pos;
        const double p_est = stats.estimate_ber();

        // payload 크기 결정 
        int payload;
        if (remaining <= (size_t)P) {
            // 남은 byte 가 P 이하면 전부 한 frame 으로
            payload = (int)remaining;
        } else if (remaining <= (size_t)P * 2 && remaining <= (size_t)P_MAX) {
            // 마지막 두 frame  남은 걸 한 frame 으로 또는 지금 P 만큼 한 번 + 나머지 한 번
            // 두 옵션의 기대 cost 비교 후 작은 쪽 선택.
            int p_merge = (int)remaining;
            int p_rest  = (int)(remaining - (size_t)P);
            double c_merge = single_frame_cost(p_merge, p_est);
            double c_asym  = single_frame_cost(P, p_est) + single_frame_cost(p_rest, p_est);
            payload = (c_merge < c_asym) ? p_merge : P;
        } else {
            
            payload = P;
        }
        if (payload < 1) payload = 1;

        // 프레임 구축
        frame[0] = (uint8_t)((payload >> 8) & 0xFF);
        frame[1] = (uint8_t)( payload       & 0xFF);

        std::memcpy(frame.data() + 2, data.data() + pos, (size_t)payload);

        uint32_t crc = compute_crc32(frame.data(), 2 + (size_t)payload);

        const int crc_off = 2 + payload;
        frame[crc_off + 0] = (uint8_t)((crc >> 24) & 0xFF);
        frame[crc_off + 1] = (uint8_t)((crc >> 16) & 0xFF);
        frame[crc_off + 2] = (uint8_t)((crc >>  8) & 0xFF);
        frame[crc_off + 3] = (uint8_t)((crc      ) & 0xFF);

        // 전송 및 블로킹
        const int frame_len = payload + OVERHEAD;
        const int rc = send_frame(frame.data(), frame_len);

        if (rc != NETSIM_ACK && rc != NETSIM_NAK) {
            std::fprintf(stderr, "send_frame() returned NETSIM_ERROR\n");
            return 1;
        }
        const bool acked = (rc == NETSIM_ACK);

        //  추정 / 컨트롤러 업데이트
        stats.observe(payload, acked);
        const int P_target = compute_optimal_payload(stats.estimate_ber());
        sizer.update_target(P_target);

        // 다음 P 결정 / pos 처리 
        if (acked) {
            pos += (size_t)payload;        // 다음 데이터로 진행
            P = sizer.on_ack(P);            // ACK의 경우 additive 증가 
        } else {
            // NAK: pos 그대로 
            P = sizer.on_nak(P);    // multiplicative 감소
        }
    }
    return 0;
}