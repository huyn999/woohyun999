#!/usr/bin/env python3
# pbsprobe/demo_web.py — 브라우저 라이브 데모 서버 (stdlib only)
#
# TV 배너처럼 생긴 페이지가 pbs(모사)의 BANR/STAT을 초당 폴링해 그린다.
#   · 살아있을 때: 채널 배너(지금/다음 방송), 시계, 가동시간, hub, crc
#   · [정지] 버튼: 처방(USR1) → criu dump → 프로세스 소멸 → 화면에 ❄ 오버레이
#     (남은 이미지 크기 표시 — "프로세스의 전부가 이 파일들")
#   · [부활] 버튼: criu restore → resume → 배너 재개
#     정지 직전의 '다음 예고'가 부활 후 '지금 방송'과 일치하면 ★ 인계 배지
#
# 실행은 demo_web.sh가 담당 (hub+앱 기동 후 이 서버를 띄움).
import json, os, re, signal, socket, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT   = int(os.environ.get("APP_PORT", "24700"))
HTTP   = int(os.environ.get("HTTP_PORT", "8899"))
D      = os.environ.get("DEMO_DIR", os.path.join(os.path.dirname(__file__), "results", "demo_live"))
IMG    = os.path.join(D, "img")
WLLOG  = os.path.join(D, "wl.log")
RESUME = os.path.join(D, "resume")
CRIU   = os.environ.get("CRIU_BIN", "")

def probe(cmd, timeout=1.2):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
        s.sendall((cmd + "\n").encode())
        s.settimeout(timeout)
        data = s.recv(512).decode(errors="replace").strip()
        s.close()
        return data
    except OSError:
        return None

def wl_pid():
    try:
        for line in open(WLLOG, errors="replace"):
            m = re.match(r"PHASE init pid=(\d+)", line)
            if m:
                pid = int(m.group(1))
        return pid
    except Exception:
        return None

def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def img_stat():
    n, total = 0, 0
    if os.path.isdir(IMG):
        for f in os.listdir(IMG):
            p = os.path.join(IMG, f)
            if os.path.isfile(p):
                n += 1
                total += os.path.getsize(p)
    return n, total

def grep_last(pat):
    try:
        out = None
        rx = re.compile(pat)
        for line in open(WLLOG, errors="replace"):
            if rx.search(line):
                out = line.strip()
        return out
    except Exception:
        return None

def first_dump_err():
    try:
        for line in open(os.path.join(IMG, "dump.log"), errors="replace"):
            if "Error" in line:
                return line.strip()[:160]
    except Exception:
        pass
    return None

def do_freeze(rx=True):
    pid = wl_pid()
    if not pid or not pid_alive(pid):
        return {"ok": False, "err": "앱이 살아있지 않음"}
    if not CRIU:
        return {"ok": False, "err": "criu 없음 (SMOKE 모드)"}
    if rx:                                              # 처방: 외부 연결 해제
        os.kill(pid, signal.SIGUSR1)
        for _ in range(60):
            if grep_last(r"hub_disconnected"):
                break
            time.sleep(0.05)
        try:
            os.remove(RESUME)
        except OSError:
            pass
    # --tcp-established는 항상 부여 → TCP는 옵션으로 구제됨을 전제하고,
    # 처방 없는 실패가 순수하게 luna hub(established UNIX) 때문임을 보인다
    r = subprocess.run([CRIU, "dump", "-t", str(pid), "-D", IMG, "-v4", "-o",
                        "dump.log", "--tcp-established"], capture_output=True)
    n, total = img_stat()
    alive_after = pid_alive(pid) and probe("PING") == "PONG"
    out = {"ok": r.returncode == 0, "rc": r.returncode, "pid": pid, "rx": rx,
           "img_files": n, "img_mib": round(total / 1048576, 1),
           "gone": not pid_alive(pid), "app_alive": alive_after}
    if r.returncode != 0:
        out["err_line"] = first_dump_err() or "(dump.log에서 Error 라인 못 찾음)"
    return out

def do_restore():
    if not CRIU:
        return {"ok": False, "err": "criu 없음 (SMOKE 모드)"}
    pidfile = os.path.join(D, "pid")
    r = subprocess.run([CRIU, "restore", "-d", "-D", IMG, "-v4", "-o",
                        "restore.log", "--pidfile", pidfile, "--tcp-established"],
                       capture_output=True)
    rpid = None
    try:
        rpid = int(open(pidfile).read().strip())
    except Exception:
        pass
    open(RESUME, "w").close()                          # 재등록 신호
    for _ in range(100):
        if grep_last(r"hub_reregistered"):
            break
        time.sleep(0.05)
    rr = grep_last(r"hub_reregistered")
    return {"ok": r.returncode == 0, "rc": r.returncode, "pid": rpid, "rereg": rr}

def state():
    b = probe("BANR")
    if b:
        m = re.match(r"BANR slot=(\d+) now=(PGM-[0-9a-f]+) next=(PGM-[0-9a-f]+)", b)
        s = probe("STAT") or ""
        crc  = re.search(r"crc=([0-9a-f]+)", s)
        hub  = re.search(r"hub=([0-9]+/[0-9]+)", s)
        up   = re.search(r"up_ms=(\d+)", s)
        return {"alive": True,
                "slot": int(m.group(1)) if m else None,
                "now": m.group(2) if m else None,
                "next": m.group(3) if m else None,
                "crc": crc.group(1) if crc else None,
                "hub": hub.group(1) if hub else None,
                "up_s": round(int(up.group(1)) / 1000, 1) if up else None,
                "clock": time.strftime("%H:%M:%S")}
    n, total = img_stat()
    return {"alive": False, "clock": time.strftime("%H:%M:%S"),
            "img_files": n, "img_mib": round(total / 1048576, 1)}

PAGE = r"""<!doctype html><html lang=ko><meta charset=utf-8>
<title>pbsprobe live — freeze &amp; restore</title>
<style>
 body{margin:0;background:#0b0f14;color:#e8eef4;font-family:system-ui,sans-serif;overflow:hidden}
 #tv{position:relative;height:100vh;background:radial-gradient(1200px 500px at 50% -10%,#17324a,#0b0f14 60%)}
 #scene{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
   color:#274b66;font-size:26px;letter-spacing:.3em}
 #banner{position:absolute;left:4%;right:4%;bottom:6%;background:rgba(10,20,30,.92);
   border:1px solid #2a4a66;border-radius:14px;padding:18px 26px;box-shadow:0 10px 40px #000a}
 .row{display:flex;justify-content:space-between;align-items:baseline;gap:16px;flex-wrap:wrap}
 #ch{font-size:15px;color:#7fb2d9}.pgm{font-size:34px;font-weight:700}
 #next{color:#9fb6c6;font-size:16px}#clk{font-size:22px;font-variant-numeric:tabular-nums}
 .meta{margin-top:10px;display:flex;gap:18px;font-size:13px;color:#8aa2b5;flex-wrap:wrap}
 .meta b{color:#cfe3f2;font-weight:600}
 #frozen{position:absolute;inset:0;display:none;align-items:center;justify-content:center;flex-direction:column;
   background:rgba(6,10,16,.82);backdrop-filter:blur(2px)}
 #frozen h1{font-size:64px;margin:0}#frozen p{color:#9fc3dd;font-size:18px}
 #handoff{display:none;margin-left:10px;background:#134;border:1px solid #2c7;color:#8fe3b0;
   border-radius:8px;padding:2px 10px;font-size:14px}
 #ctl{position:absolute;top:14px;right:16px;display:flex;gap:10px}
 button{background:#153349;color:#dff;border:1px solid #2a4a66;border-radius:10px;
   padding:10px 18px;font-size:15px;cursor:pointer}
 button:hover{background:#1d4260}button:disabled{opacity:.4;cursor:default}
 #log{position:absolute;top:14px;left:16px;font-size:12px;color:#6f8ba0;max-width:46%;
   white-space:pre-line}
</style>
<div id=tv>
 <div id=scene>· · · 방송 화면 · · ·</div>
 <div id=ctl>
   <button id=bx onclick="act('freeze_raw')">❄ 그냥 정지 시도</button>
   <button id=bf onclick="act('freeze')">❄ 처방 후 정지</button>
   <button id=br onclick="act('restore')" disabled>▶ 부활 (restore)</button>
 </div>
 <div id=log></div>
 <div id=frozen><h1>❄ FROZEN</h1><p id=fz></p></div>
 <div id=banner>
   <div class=row>
     <div><div id=ch>CH 07 · pbsprobe EPG</div>
       <div class=pgm><span id=now>—</span><span id=handoff>★ 예고→방영 인계</span></div>
       <div id=next>다음: —</div></div>
     <div id=clk>--:--:--</div>
   </div>
   <div class=meta>
     <span>가동 <b id=up>—</b></span><span>슬롯 <b id=slot>—</b></span>
     <span>hub <b id=hub>—</b></span><span>편성 crc <b id=crc>—</b></span>
   </div>
 </div>
</div>
<script>
let savedNext=null, frozen=false;
const $=id=>document.getElementById(id);
function log(t){$('log').textContent=(new Date).toLocaleTimeString()+'  '+t+'\n'+$('log').textContent.split('\n').slice(0,7).join('\n')}
async function tick(){
  try{
    const r=await fetch('/api/state'); const j=await r.json();
    $('clk').textContent=j.clock;
    if(j.alive){
      $('frozen').style.display='none';
      if(frozen){ // 부활 직후 첫 프레임: 인계 판정
        if(savedNext && j.now===savedNext){$('handoff').style.display='inline';
          log('★ 인계 성공: 정지 전 다음('+savedNext+') = 부활 후 지금('+j.now+')');}
        frozen=false; $('bf').disabled=false; $('br').disabled=true;
      }
      $('now').textContent=j.now; $('next').textContent='다음: '+j.next;
      $('slot').textContent=j.slot; $('hub').textContent=j.hub;
      $('crc').textContent=j.crc; $('up').textContent=j.up_s+'s';
    }else{
      $('frozen').style.display='flex';
      $('fz').textContent='프로세스 없음 — 남은 것은 이미지 '+j.img_files+'개 파일, '+j.img_mib+' MiB (시계는 계속 흐른다: '+j.clock+')';
    }
  }catch(e){}
  setTimeout(tick,700);
}
async function act(k){
  const url = k==='freeze_raw' ? '/api/freeze?rx=0' : '/api/'+k;
  if(k==='freeze'){savedNext=$('next').textContent.replace('다음: ','');$('bf').disabled=true;}
  log((k==='freeze_raw'?'처방 없이 dump 시도':k)+' ...');
  const r=await fetch(url,{method:'POST'}); const j=await r.json();
  if(k==='freeze_raw'){
    if(j.ok===false && j.err_line){
      const b=$('banner'); b.style.borderColor='#c33'; b.style.boxShadow='0 0 30px #c336';
      setTimeout(()=>{b.style.borderColor='#2a4a66'; b.style.boxShadow='0 10px 40px #000a';},1800);
      log('✖ dump 거부 (rc='+j.rc+'): '+j.err_line);
      log('  → 앱은 무사'+(j.app_alive?' (PONG 확인)':'')+' — 실패는 비파괴적. luna hub established가 원인');
    } else if(j.ok){log('!? 처방 없이 성공 — hub 연결 상태 확인 필요');}
    else log('실패: '+(j.err||('rc='+j.rc)));
    return;
  }
  if(k==='freeze'&&j.ok){frozen=true;$('br').disabled=false;
    log('★ dump rc=0 → pid '+j.pid+' 소멸, 이미지 '+j.img_mib+' MiB — 처방(연결해제) 덕분');}
  else if(k==='restore'&&j.ok){log('restore rc='+j.rc+' → pid '+j.pid+' 부활, 재등록 완료');}
  else log('실패: '+(j.err||('rc='+j.rc)));
}
tick();
</script>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _json(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/api/state":
            return self._json(state())
        b = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        if self.path.startswith("/api/freeze"):
            rx = "rx=0" not in self.path
            return self._json(do_freeze(rx))
        if self.path == "/api/restore":
            return self._json(do_restore())
        self._json({"ok": False, "err": "unknown"}, 404)

if __name__ == "__main__":
    print(f"[web] http://<이 기기 IP>:{HTTP}/  (앱 포트 {PORT}, criu={'있음' if CRIU else 'SMOKE'})")
    ThreadingHTTPServer(("0.0.0.0", HTTP), H).serve_forever()
