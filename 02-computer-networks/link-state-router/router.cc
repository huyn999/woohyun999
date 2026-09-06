
#include "netsim2.h"
#include <cstdint>
#include <vector>
namespace {
constexpr int DOWN = NETSIM2_NO_LINK;
constexpr int COST_SUPPRESS = 100;

// 노드 id 하나를 담는 데 필요한 비트 수 
int idWidth(int n) {
    int b = 1;
    while ((1 << b) < n)
        ++b;
    return b;
}
} 

// 라우터 1개의 전체 상태. router_init에서 할당, router_shutdown에서 해제.
struct RouterState {
    int myId;                  // 내 노드 id 
    int numNodes;              // 전체 노드 수 N
    int idBits;                // 노드 id 1개를 담는 비트 수
    std::vector<int> linkCost; // linkCost[v] = 이웃 v로의 링크 비용, 없으면 DOWN(-1)
    std::vector<int> lsaSeq;   // lsaSeq[u] = u에 대해 내가 아는 최신 LSA seq, 모르면 -1
    std::vector<std::vector<int>> adj; // adj[u][v]=1 
    std::vector<int> nextHop; // nextHop[dst] = 최단경로상 dst로 가는 첫 hop 
    std::vector<int> lastPick; // lastPick[dst] = 직전에 dst로 고른 next-hop 
    std::vector<int> rotorPos; // rotorPos[dst] = fallback 우회 시 회전 커서 역할
    std::vector<int> repeatCnt; // repeatCnt[dst] = 같은 next-hop 연속 선택 횟수 
    bool routesDirty;      // 토폴로지 변경됨 표시 다음 on_packet에서 경로 재계산 필요
    bool needFlood;        // 내 LSA를 다시 flood해야 함
    bool wakePending;      // schedule_wakeup 예약됨
    std::vector<std::vector<char>>
        alreadyHas;            // 이웃 v가 O의 현재 LSA를 이미 가짐
    std::vector<int> bufSeq;   // bufSeq[O] = relay 대기 중인 O의 LSA seq, 없으면 -1
    bool flushPending;         // 버퍼된 relay flush가 예약됨
};
namespace {
//비트 단위 직렬화: LSA/digest를 바이트가 아닌 비트로  팩
// 비트 출력 버퍼.
struct BitWriter {
    uint8_t *buf;
    int pos;
};
// value의 하위 nbits 비트를 버퍼에 MSB-first로 기록
void writeBits(BitWriter &s, int value, int nbits) {
    for (int i = nbits - 1; i >= 0; --i) {
        int bi = s.pos >> 3, bo = 7 - (s.pos & 7);
        if (bo == 7)
            s.buf[bi] = 0;
        if ((value >> i) & 1)
            s.buf[bi] |= (1 << bo);
        ++s.pos;
    }
}
// 비트 입력 버퍼
struct BitReader {
    const uint8_t *buf;
    int pos;
};
// 버퍼에서 nbits 비트를 읽어 정수로 반환
int readBits(BitReader &s, int nbits) {
    int v = 0;
    for (int i = 0; i < nbits; ++i) {
        int bi = s.pos >> 3, bo = 7 - (s.pos & 7);
        v = (v << 1) | ((s.buf[bi] >> bo) & 1);
        ++s.pos;
    }
    return v;
}
// 비트 길이를 바이트 길이로 올림.
int bitsToBytes(int nbits) {
    return (nbits + 7) >> 3;
}
// LSA seq를 가변길이로 기록
void writeSeq(BitWriter &s, int q) {
    if (q <= 8) {
        writeBits(s, 0, 1);
        writeBits(s, q - 1, 3);
    } else if (q < 128) {
        writeBits(s, 1, 1);
        writeBits(s, 0, 1);
        writeBits(s, q, 7);
    } else {
        writeBits(s, 1, 1);
        writeBits(s, 1, 1);
        writeBits(s, q, 16);
    }
}
// writeSeq로 쓴 가변길이 seq를 복원
int readSeq(BitReader &s) {
    if (readBits(s, 1) == 0)
        return readBits(s, 3) + 1;
    if (readBits(s, 1) == 0)
        return readBits(s, 7);
    return readBits(s, 16);
}
// 개수를 담는 비트 수
int countWidth(int n) {
    int b = 1;
    while ((1 << b) <= n)
        ++b;
    return b;
}

// LSA 1개를 buf에 직렬화. directed는 who보다 큰 id의 이웃만 싣는다
int encodeLsa(int idw, int who, int q, const char *hi, int n, uint8_t *buf) {
    int lo = who + 1; // 상위 이웃만
    int mw = countWidth(n), deg = 0;
    for (int v = lo; v < n; ++v)
        if (hi[v])
            ++deg;
    int cand = n - 1 - who;
    int list_bits = 1 + mw + deg * idw;
    int bitmap_bits = 1 + cand;
    int mode = (bitmap_bits < list_bits) ? 1 : 0;
    for (int i = 0; i < 256; ++i)
        buf[i] = 0;
    BitWriter w{buf, 0};
    writeBits(w, (q == 0) ? 0 : 1, 1);
    writeBits(w, who, idw);
    if (q != 0)
        writeSeq(w, q);
    if (mode == 0) {
        writeBits(w, 0, 1);
        writeBits(w, deg, mw);
        for (int v = lo; v < n; ++v)
            if (hi[v])
                writeBits(w, v, idw);
    } else {
        writeBits(w, 1, 1);
        for (int v = lo; v < n; ++v)
            writeBits(w, hi[v] ? 1 : 0, 1);
    }
    return bitsToBytes(w.pos);
}
// 내 현재 이웃 집합으로 내 LSA를 직렬화.
int encodeMyLsa(const RouterState *s, uint8_t *buf) {
    int n = s->numNodes;
    int q = s->lsaSeq[s->myId];
    char hi[128];
    for (int v = 0; v < n; ++v)
        hi[v] = (v > s->myId && s->linkCost[v] >= 1) ? 1 : 0;
    return encodeLsa(s->idBits, s->myId, q, hi, n, buf);
}
// 내가 알고 있는 origin u의 토폴로지(adj[u])로 u의 LSA를 재구성
int encodeOriginLsa(const RouterState *s, int u, uint8_t *buf) {
    int n = s->numNodes;
    int q = s->lsaSeq[u];
    char hi[128];
    for (int v = 0; v < n; ++v)
        hi[v] = (v > u && s->adj[u][v] >= 1) ? 1 : 0;
    return encodeLsa(s->idBits, u, q, hi, n, buf);
}

// 상위 이웃이 하나도 없으면 LSA를 보낼 필요가 없다
bool hasHigherNbr(const RouterState *s) {
    for (int v = s->myId + 1; v < s->numNodes; ++v)
        if (s->linkCost[v] >= 1)
            return true;
    return false;
}
// 내 LSA를 모든 up 이웃에게 보냄
void floodMyLsa(RouterState *s) {
    if (s->lsaSeq[s->myId] == 0 && !hasHigherNbr(s))
        return;
    uint8_t buf[256];
    int len = encodeMyLsa(s, buf);
    for (int v = 0; v < s->numNodes; ++v)
        if (s->linkCost[v] >= 1)
            send_control(v, buf, len);
}

// 내가 아는 (origin, seq) 목록 요약을 새로 붙은 이웃에게 보내서 빠진 LSA 동기화
void sendDigest(RouterState *s, int neighbor) {
    uint8_t buf[256];
    for (int i = 0; i < 256; ++i)
        buf[i] = 0;
    int n = s->numNodes, idw = s->idBits, mw = countWidth(n);
    int known = 0;
    for (int u = 0; u < n; ++u)
        if (s->lsaSeq[u] >= 0)
            ++known;
    bool use_list = (mw + known * idw) < n;
    BitWriter w{buf, 0};
    writeBits(w, 0, 1);
    writeBits(w, neighbor, idw);
    writeBits(w, use_list ? 1 : 0, 1);
    if (use_list) {
        writeBits(w, known, mw);
        for (int u = 0; u < n; ++u)
            if (s->lsaSeq[u] >= 0) {
                writeBits(w, u, idw);
                writeSeq(w, s->lsaSeq[u] + 1);
            }
    } else {
        for (int u = 0; u < n; ++u) {
            if (s->lsaSeq[u] >= 0) {
                writeBits(w, 1, 1);
                writeSeq(w, s->lsaSeq[u] + 1);
            } else
                writeBits(w, 0, 1);
        }
    }
    send_control(neighbor, buf, bitsToBytes(w.pos));
}
// 상대 digest를 받아, 내가 더 최신인 origin들의 LSA를 골라 보내줌
void replyDigest(RouterState *s, int from, const uint8_t *p, int len) {
    int n = s->numNodes, idw = s->idBits, mw = countWidth(n);
    BitReader r{p, 0};
    if (len * 8 < 2 + idw)
        return;
    readBits(r, 1);
    readBits(r, idw);
    int use_list = readBits(r, 1);
    int their[128];
    for (int u = 0; u < n; ++u)
        their[u] = -1;
    if (use_list) {
        int known = readBits(r, mw);
        for (int i = 0; i < known; ++i) {
            int u = readBits(r, idw);
            int q = readSeq(r) - 1;
            if (u >= 0 && u < n)
                their[u] = q;
        }
    } else {
        for (int u = 0; u < n; ++u)
            if (readBits(r, 1))
                their[u] = readSeq(r) - 1;
    }
    uint8_t buf[256];
    for (int u = 0; u < n; ++u) {
        if (s->lsaSeq[u] < 0)
            continue;
        if (s->lsaSeq[u] > their[u]) {
            int l = (u == s->myId) ? encodeMyLsa(s, buf) : encodeOriginLsa(s, u, buf);
            send_control(from, buf, l);
        }
    }
}

// 엣지 존재 여부는 낮은 id 쪽이 보고한 것으로 판단
inline int edgeUp(const RouterState *s, int a, int b) {
    if (a == b)
        return 0;
    if (a == s->myId)
        return s->linkCost[b] >= 1;
    if (b == s->myId)
        return s->linkCost[a] >= 1;
    return (s->adj[a][b] >= 1) || (s->adj[b][a] >= 1);
}
// 현재 토폴로지 뷰로 나에서 각 dst까지 최단경로, 첫 hop을 계산해 nextHop에 저장.
void recomputeRoutes(RouterState *s) {
    const int n = s->numNodes, INF = 0x3f3f3f3f;
    std::vector<int> dist(n, INF), first(n, -1);
    std::vector<char> done(n, 0);
    dist[s->myId] = 0;
    for (int it = 0; it < n; ++it) {
        int u = -1, best = INF;
        for (int i = 0; i < n; ++i)
            if (!done[i] && dist[i] < best) {
                best = dist[i];
                u = i;
            }
        if (u < 0)
            break;
        done[u] = 1;
        for (int v = 0; v < n; ++v) {
            if (!edgeUp(s, u, v))
                continue;
            int w = 1;
            if (dist[u] + w < dist[v]) {
                dist[v] = dist[u] + w;
                first[v] = (u == s->myId) ? v : first[u];
            }
        }
    }
    s->nextHop = first;
    s->routesDirty = false;
}
// 수신한 LSA를 파싱해 adj[origin]을 갱신. 더 새 seq일 때만 적용
bool applyLsa(RouterState *s, const uint8_t *p, int len) {
    int idw = s->idBits;
    if (len * 8 < 1 + idw)
        return false;
    BitReader r{p, 0};
    int flag = readBits(r, 1);
    int origin = readBits(r, idw);
    int rseq_val = flag ? readSeq(r) : 0;
    if (origin < 0 || origin >= s->numNodes || origin == s->myId)
        return false;
    int q;
    if (flag == 0)
        q = (s->lsaSeq[origin] < 0) ? 0 : -1;
    else
        q = (rseq_val > s->lsaSeq[origin]) ? rseq_val : -1;
    if (q < 0)
        return false;
    int n = s->numNodes;
    std::vector<int> &row = s->adj[origin];
    for (int v = 0; v < n; ++v)
        row[v] = DOWN;
    if (r.pos >= len * 8) {
        s->lsaSeq[origin] = q;
        s->routesDirty = true;
        return true;
    }
    int mode = readBits(r, 1);
    int lo = origin + 1; // directed, 상위 이웃만
    if (mode == 0) {
        int mw = countWidth(n);
        int deg = readBits(r, mw);
        for (int i = 0; i < deg; ++i) {
            int v = readBits(r, idw);
            if (v >= 0 && v < n && v != origin)
                row[v] = 1;
        }
    } else {
        for (int v = lo; v < n; ++v) {
            if (v == origin)
                continue;
            if (readBits(r, 1))
                row[v] = 1;
        }
    }
    s->lsaSeq[origin] = q;
    s->routesDirty = true;
    return true;
}
} 
// LSA payload를 건드리지 않고 origin id만 빠르게 읽음
int peekOrigin(const RouterState *s, const uint8_t *p) {
    BitReader r{p, 0};
    readBits(r, 1);
    return readBits(r, s->idBits);
}
// 마찬가지로 seq만 미리 읽음.
int peekSeq(const RouterState *s, const uint8_t *p) {
    BitReader r{p, 0};
    int f = readBits(r, 1);
    readBits(r, s->idBits);
    return f ? readSeq(r) : 0;
}
#ifndef OVERHEAR_DELAY
#define OVERHEAR_DELAY 16
#endif

// 내 토폴로지 뷰에서 origin O로부터의 hop 거리를 bfs이용해 측정. relay 가지치기용.
static void bfsFromOrigin(const RouterState *s, int O, int *d) {
    const int INF = 1 << 29, n = s->numNodes;
    for (int v = 0; v < n; ++v)
        d[v] = INF;
    int q[256], h = 0, t = 0;
    if (O < 0 || O >= n)
        return;
    d[O] = 0;
    q[t++] = O;
    while (h < t) {
        int u = q[h++];
        for (int v = 0; v < n; ++v) {
            if (d[v] < INF)
                continue;
            if (edgeUp(s, u, v)) {
                d[v] = d[u] + 1;
                q[t++] = v;
            }
        }
    }
}
// 버퍼에 쌓인 relay를 한 번에 처리. 이미 가진 이웃/뒤쪽 이웃은 생략.
void flushBufferedRelays(RouterState *s) {
    uint8_t buf[256];
    const int INF = 1 << 29;
    int dO[256];
    for (int O = 0; O < s->numNodes; ++O) {
        if (s->bufSeq[O] < 0)
            continue;
        int len = (O == s->myId) ? encodeMyLsa(s, buf) : encodeOriginLsa(s, O, buf);
        bfsFromOrigin(s, O, dO);
        int dme = dO[s->myId];
        for (int v = 0; v < s->numNodes; ++v) {
            if (s->linkCost[v] < 1 || v == O)
                continue;
            if (s->alreadyHas[O][v])
                continue;
            // 방향성: v가 O로부터 나보다 가깝거나 같으면 중계 생략. 단 거리 불명이면 보냄
            if (dme < INF && dO[v] < INF && dO[v] <= dme)
                continue;
            send_control(v, buf, len);
        }
        s->bufSeq[O] = -1;
    }
    s->flushPending = false;
}


//  초기 이웃 등록 후 내 LSA를 최초 flood.
struct RouterState *router_init(int my_id, int num_nodes, const int *neighbor_ids,const int *link_costs, int num_neighbors) 
{
    RouterState *s = new RouterState();
    s->myId = my_id;
    s->numNodes = num_nodes;
    s->idBits = idWidth(num_nodes);
    s->linkCost.assign(num_nodes, DOWN);
    s->lsaSeq.assign(num_nodes, -1);
    s->adj.assign(num_nodes, std::vector<int>(num_nodes, DOWN));
    s->nextHop.assign(num_nodes, -1);
    s->lastPick.assign(num_nodes, -1);
    s->rotorPos.assign(num_nodes, -1);
    s->repeatCnt.assign(num_nodes, 0);
    s->routesDirty = true;
    s->needFlood = false;
    s->wakePending = false;
    s->alreadyHas.assign(num_nodes, std::vector<char>(num_nodes, 0));
    s->bufSeq.assign(num_nodes, -1);
    s->flushPending = false;
    for (int i = 0; i < num_neighbors; ++i)
        s->linkCost[neighbor_ids[i]] = link_costs[i];
    s->lsaSeq[my_id] = 0;
    floodMyLsa(s);
    return s;
}

// 내 링크 비용 변화/끊김/복구, 작은 비용 변화는 무시
// 내 상위 이웃 집합이 바뀌면 LSA 재flood 예약, 링크 복구 시 digest로 재동기화.
void on_link_change(struct RouterState *s, int neighbor, int new_cost) {
    int prev = s->linkCost[neighbor];
    if (new_cost != DOWN && prev >= 1) {
        int df = new_cost - prev;
        if (df < 0)
            df = -df;
        if (df < COST_SUPPRESS)
            return;
    }
    bool need_sync = (new_cost != DOWN && prev < 1);
    s->linkCost[neighbor] = (new_cost == DOWN) ? DOWN : new_cost;
    s->routesDirty = true;
    // 내 상위 이웃 집합이 바뀔 때만 재flooding
    if (neighbor > s->myId) {
        s->lsaSeq[s->myId] += 1;
        s->needFlood = true;
        if (!s->wakePending) {
            s->wakePending = true;
            schedule_wakeup(get_now());
        }
    }
    if (need_sync)
        sendDigest(s, neighbor);
}

// 제어 메시지 수신, 내 origin이면 digest 응답, 아니면 LSA 적용 후(overhearing/가지치기 규칙에 따라) 다른 이웃에게 relay.
void on_control(struct RouterState *s, int from, const uint8_t *payload, int len) {
    if (peekOrigin(s, payload) == s->myId) {
        replyDigest(s, from, payload, len);
        return;
    }
    int pO = peekOrigin(s, payload), pq = peekSeq(s, payload), pf = (payload[0] >> 7) & 1;
    bool applied = applyLsa(s, payload, len);
    if (pO >= 0 && pO < s->numNodes && s->bufSeq[pO] == pq)
        s->alreadyHas[pO][from] = 1; 
    if (!applied)
        return;
    int origin = pO;
    int mydeg = 0;
    for (int v = 0; v < s->numNodes; ++v)
        if (s->linkCost[v] >= 1)
            ++mydeg;
    bool buffer_it = (pf == 0) || (s->numNodes >= 16 && mydeg > 2);
    if (buffer_it) {
        s->bufSeq[origin] = pq;
        for (int v = 0; v < s->numNodes; ++v)
            s->alreadyHas[origin][v] = 0;
        s->alreadyHas[origin][from] = 1;
        if (!s->flushPending) {
            s->flushPending = true;
            int dl = (mydeg <= 2) ? 0 : OVERHEAR_DELAY;
            schedule_wakeup(get_now() + dl);
        }
        return;
    }
    for (int v = 0; v < s->numNodes; ++v) {
        if (s->linkCost[v] < 1 || v == from || v == origin)
            continue;
        send_control(v, payload, len);
    }
}

// start에서 avoid 노드를 빼고 dst에 도달 가능한지 판단
static bool reachableAvoiding(const RouterState *s, int start, int dst, int avoid) {
    const int n = s->numNodes;
    char vis[256];
    int q[256], h = 0, t = 0;
    if (start < 0 || start >= n || start == avoid || dst < 0 || dst >= n || dst == avoid)
        return false;
    for (int i = 0; i < n; ++i)
        vis[i] = 0;
    vis[start] = 1;
    q[t++] = start;
    while (h < t) {
        int u = q[h++];
        if (u == dst)
            return true;
        for (int v = 0; v < n; ++v) {
            if (v == avoid || vis[v])
                continue;
            if (!edgeUp(s, u, v))
                continue;
            vis[v] = 1;
            q[t++] = v;
        }
    }
    return false;
}
// dst로부터의 hop 거리 측정, 우회 대안 중 더 가까운 것을 고를 때 사용.
static void bfsFromDst(const RouterState *s, int dst, int *d) {
    const int INF = 1 << 29, n = s->numNodes;
    for (int v = 0; v < n; ++v)
        d[v] = INF;
    int q[256], h = 0, t = 0;
    if (dst < 0 || dst >= n)
        return;
    d[dst] = 0;
    q[t++] = dst;
    while (h < t) {
        int u = q[h++];
        for (int v = 0; v < n; ++v) {
            if (d[v] < INF)
                continue;
            if (edgeUp(s, u, v)) {
                d[v] = d[u] + 1;
                q[t++] = v;
            }
        }
    }
}

#ifndef LOOP_LIMIT
#define LOOP_LIMIT 2
#endif
//  dst로 갈 next hop 반환
int on_packet(struct RouterState *s, int dst) {
    if (s->routesDirty)
        recomputeRoutes(s);
    int nh = s->nextHop[dst];
    if (nh >= 0 && s->linkCost[nh] >= 1) {
        if (nh == s->lastPick[dst])
            ++s->repeatCnt[dst];
        else
            s->repeatCnt[dst] = 0;
        int chosen = nh;
        if (s->repeatCnt[dst] >= LOOP_LIMIT) {
            int dd[256];
            bfsFromDst(s, dst, dd);
            const int INF = 1 << 29;
            int alt = -1, altd = INF;
            for (int v = 0; v < s->numNodes; ++v) {
                if (s->linkCost[v] < 1 || v == nh)
                    continue;
                if (!reachableAvoiding(s, v, dst, s->myId))
                    continue; // 내 노드 피해 dst 도달 가능할 때만
                int dv = edgeUp(s, s->myId, v) ? dd[v] : INF;
                if (dv < INF && dv < altd) {
                    altd = dv;
                    alt = v;
                }
            }
            if (alt >= 0) {
                chosen = alt;
                s->repeatCnt[dst] = 0;
            } else
                s->repeatCnt[dst] = 0;
        }
        s->lastPick[dst] = chosen;
        return chosen;
    }
    int n = s->numNodes;
    int my = s->myId;
    int my_dist = my > dst ? my - dst : dst - my;
    const int MAXN = 256;
    int deg[MAXN];
    char removed[MAXN];
    char known[MAXN];
    for (int v = 0; v < n; ++v) {
        known[v] = (v == my) || (s->lsaSeq[v] >= 0);
        removed[v] = 0;
    }
    for (int v = 0; v < n; ++v) {
        int d = 0;
        for (int w = 0; w < n; ++w)
            if (edgeUp(s, v, w))
                ++d;
        deg[v] = d;
    }
    char frontier[MAXN];
    for (int v = 0; v < n; ++v) {
        frontier[v] = 0;
        if (!known[v])
            continue;
        for (int w = 0; w < n; ++w)
            if (edgeUp(s, v, w) && !known[w]) {
                frontier[v] = 1;
                break;
            }
    }
    int changed = 1;
    while (changed) {
        changed = 0;
        for (int v = 0; v < n; ++v) {
            if (removed[v] || v == dst || v == my)
                continue;
            if (!known[v] || frontier[v])
                continue;
            if (deg[v] <= 1) {
                removed[v] = 1;
                changed = 1;
                for (int w = 0; w < n; ++w)
                    if (!removed[w] && edgeUp(s, v, w))
                        --deg[w];
            }
        }
    }
    char sleaf[MAXN];
    for (int v = 0; v < n; ++v) {
        if (v == my || v == dst) {
            sleaf[v] = 0;
            continue;
        }
        int d2 = 0;
        for (int w = 0; w < n; ++w)
            if (edgeUp(s, v, w))
                ++d2;
        sleaf[v] = (d2 <= 1);
    }
    int chosen = -1;
    int updeg = 0;
    for (int v = 0; v < n; ++v)
        if (s->linkCost[v] >= 1)
            ++updeg;
    if (updeg <= 2) {
        int pick = -1, pick_dist = my_dist;
        for (int v = 0; v < n; ++v) {
            if (s->linkCost[v] < 1)
                continue;
            if (v != dst && removed[v])
                continue;
            int d = v > dst ? v - dst : dst - v;
            if (d < pick_dist) {
                pick_dist = d;
                pick = v;
            }
        }
        if (pick >= 0)
            chosen = pick;
    }
    if (chosen < 0) {
        int pick = -1, pick_cost = -1;
        for (int v = 0; v < n; ++v) {
            if (s->linkCost[v] < 1)
                continue;
            if (v != dst && removed[v])
                continue;
            if (s->linkCost[v] > pick_cost) {
                pick_cost = s->linkCost[v];
                pick = v;
            }
        }
        chosen = pick;
    }
    if (chosen < 0) {
        int pick = -1, pick_cost = -1;
        for (int v = 0; v < n; ++v)
            if (s->linkCost[v] >= 1 && s->linkCost[v] > pick_cost) {
                pick_cost = s->linkCost[v];
                pick = v;
            }
        chosen = pick;
    }
    if (chosen >= 0 && chosen == s->lastPick[dst]) {
        int cand[MAXN], nc = 0;
        for (int v = 0; v < n; ++v)
            if (s->linkCost[v] >= 1 && v != chosen && (v == dst || !sleaf[v]))
                cand[nc++] = v;
        if (nc == 0)
            for (int v = 0; v < n; ++v)
                if (s->linkCost[v] >= 1 && v != chosen)
                    cand[nc++] = v;
        if (nc > 0) {
            int nx = -1;
            for (int i = 0; i < nc; ++i)
                if (cand[i] > s->rotorPos[dst]) {
                    nx = cand[i];
                    break;
                }
            if (nx < 0)
                nx = cand[0];
            s->rotorPos[dst] = nx;
            chosen = nx;
        }
    }
    s->lastPick[dst] = chosen;
    return chosen;
}
// 예정된 시각 도달, 버퍼된 relay flush 및 대기 중 LSA flood
void on_timer(struct RouterState *s) {
    if (s->flushPending)
        flushBufferedRelays(s);
    if (s->needFlood) {
        s->needFlood = false;
        floodMyLsa(s);
    }
    s->wakePending = false;
}

void router_shutdown(struct RouterState *s) {
    delete s;
}