#!/bin/bash
# auto_root.sh —— 精简包一键入口：安全确认 → adb/设备检查 → 固件版本检测 → 幂等预置 → 磨机 → 实时回报
# 双固件支持：连接后自动检测设备固件（A.89 / A.92），刷入对应版本的镜像套件；
# 版本无法识别时直接停止。
# 由 一键Root.bat 调用（也可直接 bash auto_root.sh）。Exit codes:
#   0=uid0 达成   2=未命中（用户中断/轮数用尽）  3=环境或预置失败
#   4=设备不可用  5=用户在安全确认选择了 n       6=设备已经是 uid=0（刷写前闸门拦下）
#   130=Ctrl+C
set -u
export MSYS_NO_PATHCONV=1
# D 做成函数（定义在一切使用之前）：每次调用自带 20s 超时 + 关闭 stdin
# （adb 会偷吃脚本 stdin，吞掉后续 read 的答案——kit 时代的老坑）
# 序列号不写死：阶段 1 自动选（唯一设备直接选，多设备交互选），结果 export 到 RC_SERIAL
D(){ timeout 20 adb -s "${RC_SERIAL:?未选定设备}" "$@" </dev/null; }
cd "$(cd "$(dirname "$0")" && pwd)" || exit 3
HUNT="rc17_hunt_v2.sh"
APP_MD5="292c5b49c088fd844578f83af9c97728"
# 以下变量由「阶段 1.5 固件版本检测」按检测结果赋值（A.89 / A.92 两套）：
BOOT=""; BOOT_MD5=""; REC_IMG=""; REC_MD5=""; GUARD=""
SER="${RC_SERIAL:-}"
HUNT_LOG="auto_root_hunt.log"
ok(){ printf '  ✓ %s\n' "$*"; }
bad(){ printf '  ✗ %s\n' "$*"; }
hr(){ printf '%s\n' "------------------------------------------------------------"; }

hr; echo "  OPPO Watch 2 (OW20W1) 一键永久 Root"; hr

# ============ 阶段 0：安全事项 + y/n ============
cat <<'EOF'

【安全事项 —— 请务必阅读后再决定】
 1. 本工具通过设备上载体 App 的内核漏洞（fastrpc UAF）获取 uid=0，
    并在命中后【自动把 boot 分区刷成 v7 镜像】（永久 root + 无线 adb + 开机 Permissive + setenforce 自由开关）。
    刷入哪套镜像（A.89 / A.92）由连接后【自动检测的固件版本】决定，检测不出会直接停止。
 2. 磨机期间设备【每 1–2 分钟自动复位一次】，持续约 35–45 分钟（均值），
    期间请不要拔线、不要操作手表。
 3. 刷写带回读校验、且守卫只对原厂 boot 放行（不会覆盖已打补丁的 boot），
    但本设备【没有 EDL 兜底】——若刷写途中断电/拔线，存在不可逆变砖风险，
    虽然概率很小。请保持 USB 供电稳定。
 4. 命中后系统会短暂进入 Permissive（SELinux 全开放），持续数秒~数十秒。
 5. 过程中会在手表上安装载体 App（com.gc.p2）并写入 /data/local/tmp 若干文件。
 6. 仅限在你【自己的设备】上做安全研究；刷机有失去保修的风险。

EOF
printf '  确认已理解并继续？(y/N): '
read -r a
case "$a" in y|Y|yes|YES) echo "  → 继续";; *) echo "  → 已取消，未做任何更改。"; exit 5;; esac

# ============ 阶段 1：adb 驱动与设备连接检查 ============
hr; echo "[1/4] adb 与设备连接检查"
command -v adb >/dev/null 2>&1 || { bad "adb 不在 PATH —— 请安装 platform-tools 并加入 PATH"; exit 3; }
ok "adb: $(adb version 2>/dev/null </dev/null | head -1)"
try=0
while :; do
  mapfile -t DEVS < <(adb devices 2>/dev/null </dev/null | awk 'NR>1 && $2=="device"{print $1}')
  [ ${#DEVS[@]} -gt 0 ] && break
  try=$((try+1))
  [ $try -gt 10 ] && { bad "5 分钟内未发现设备。检查：数据线/USB 调试/授权弹窗/驱动"; exit 4; }
  echo "  [$try/10] 未发现设备 —— 请插好 USB 并允许调试授权，30 秒后自动重试…"
  sleep 30
done
if [ ${#DEVS[@]} -eq 1 ]; then SER=${SER:-${DEVS[0]}}; fi
if [ -z "$SER" ]; then
  echo "  检测到多台设备，请输入要操作的序列号："
  i=1; for d in "${DEVS[@]}"; do echo "    $i) $d"; i=$((i+1)); done
  read -r n; SER=${DEVS[$((n-1))]}
fi
[ -n "$SER" ] || { bad "未选定设备"; exit 4; }
export RC_SERIAL="$SER"
ST=$(D get-state 2>/dev/null | tr -d '\r')
[ "$ST" = "device" ] && ok "设备 $SER 在线（$ST）" || { bad "设备 $SER 状态异常（${ST:-无}）"; exit 4; }
ok "后续所有命令已钉定序列号: $SER"

# ============ 阶段 1.2：设备已 root 状态检测（刷写前强制闸门） ============
# 目的：设备已经是 uid=0 时**立即停下**。已 root 的设备再跑一遍磨机没有意义，
# 而 boot/recovery 会被重复刷写——分区是无损操作，但重复刷写等于把风险重下一遍。
# 放在固件检测与任何推送之前：这是最早的拦截点。
hr; echo "[1.2/4] 设备 root 状态检测（刷写前闸门）"
CUR_UID=$(D shell 'id -u' 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9]+$')
[ -z "$CUR_UID" ] && CUR_UID="unknown"
CUR_DBG=$(D shell 'getprop ro.debuggable' 2>/dev/null | tr -d '\r\n')
CUR_ENF=$(D shell 'getenforce' 2>/dev/null | tr -d '\r\n')

if [ "$CUR_UID" = "0" ]; then
  echo ""
  echo ""
  echo "  ================================================================"
  echo "     [STOP] 检测到设备已经是 root（uid=0），脚本已停止"
  echo "  ================================================================"
  echo ""
  echo "    序列号      : $SER"
  echo "    shell uid   : $CUR_UID"
  echo "    ro.debuggable: ${CUR_DBG:-?}"
  echo "    SELinux     : ${CUR_ENF:-?}"
  echo ""
  echo "  你已经拿到 root 了，不需要再跑提权。重复执行只会把 boot / recovery"
  echo "  再刷一遍——分区本身无损，但没有任何必要。"
  echo ""
  echo "  如果你只是想把 TWRP 换成别的版本，不需要磨机，直接用维护通道："
  echo "    adb -s $SER reboot recovery"
  echo "    adb -s $SER push <新recovery镜像> /tmp/rec.img"
  echo "    adb -s $SER shell 'dd if=/tmp/rec.img of=/dev/block/bootdevice/by-name/recovery bs=4096'"
  echo "  详见 README《维护通道》。"
  echo ""
  exit 6
fi

if [ "$CUR_DBG" = "1" ]; then
  echo "  ⚠ ro.debuggable=1：boot 已是永久 root 版本（uid 仍是 $CUR_UID）。"
  echo "    守卫不会放行刷写（非原厂 boot），磨机仍可跑出 Permissive 窗口。"
else
  ok "设备未 root（shell uid=$CUR_UID，ro.debuggable=${CUR_DBG:-?}，SELinux=${CUR_ENF:-?}）—— 可以继续"
fi

# ============ 阶段 1.5：固件版本检测（决定刷入哪套镜像） ============
hr; echo "[1.5/4] 固件版本检测（决定刷入的镜像套件）"
VER=$(D shell 'getprop ro.build.display.id' 2>/dev/null | tr -d '\r')
VUTC=$(D shell 'getprop ro.bootimage.build.date.utc' 2>/dev/null | tr -d '\r')
case "$VER" in
  *A.89*) PROFILE="A.89";;
  *A.92*) PROFILE="A.92";;
  *) case "$VUTC" in
       1724329644) PROFILE="A.89";;    # 2024-08-22 构建（= A.89）
       1739333172) PROFILE="A.92";;    # 2025-02-12 构建（= A.92）
       *) bad "无法识别固件版本（display.id='${VER:-?}'，boot 构建时间戳='${VUTC:-?}'）"
          bad "本工具当前只支持 A.89 / A.92 两个固件；为避免刷错镜像，已停止（未做任何更改）。"
          exit 3;;
     esac;;
esac
if [ "$PROFILE" = "A.89" ]; then
  BOOT="boot_wifiadb_v7_policy_a89.img"
  BOOT_MD5="2e06f10a58d1be0ddeef7f4ccab15ec2"
  REC_IMG="twrp-3.7.0_9-ow20w3-recovery_v8_A89.img"
  REC_MD5="3be551bb6199ce760ab97b69efa602b8"
  GUARD="184546148"                     # A.89 原厂 boot 前 1MB 的 FNV-1a 32
else
  BOOT="boot_wifiadb_v7_policy_a92.img"
  BOOT_MD5="ab62f167eab2983a43bd419af600c9a3"
  REC_IMG="twrp-3.7.0_9-ow20w3-recovery_v8_A92.img"
  REC_MD5="5baf207d746fcb6f0e2689ba833e7bdf"
  GUARD="4259604844"                    # A.92 原厂 boot 前 1MB 的 FNV-1a 32
fi
ok "设备固件: ${VER:-未知}（boot 构建 ${VUTC:-?}）→ 镜像套件【$PROFILE】"
ok "  boot 刷写目标 : $BOOT"
ok "  维护 recovery : $REC_IMG"
ok "  刷写守卫 FNV  : $GUARD（仅当 boot 仍是该版原厂时放行）"
export REC_IMG

# ============ 阶段 1.6：镜像选择（磨机/获取 uid0 之前，可手动改刷入目标） ============
# 自动检测只是默认值；这里允许在【开跑之前】直接指定要刷哪个 recovery 镜像。
# 场景：自动检测认错版本、想刷原厂 recovery 回滚、想刷另一个固件套件的镜像、自备镜像。
hr; echo "[1.6/4] 镜像选择（回车 = 用上面自动选中的 $REC_IMG）"
_bd() { [ -f "$1" ]; }
# ★ 这里只能选 recovery 镜像。boot_wifiadb_*.img 是 boot 分区的刷写目标，
#   选中会被当成 recovery 写进 p51 ⇒ 直接毁掉 recovery 分区，必须排除。
_opts=()
while IFS= read -r _f; do _opts+=("$_f"); done <<< "$(
  ls -1 ./*.img 2>/dev/null | sed 's#^\./##' |
  grep -i 'recovery' | grep -v 'boot_wifiadb' | sort
)"
if [ ${#_opts[@]} -eq 0 ]; then
  bad "当前目录下没有任何 recovery 镜像可选（*recovery*.img）"; exit 3
fi
_i=0
for _f in "${_opts[@]}"; do
  _i=$((_i+1))
  _mark="  "
  [ "$_f" = "$REC_IMG" ] && _mark="★ "
  if _bd "$_f"; then _sz=$(stat -c%s "$_f"); else _sz=0; fi
  printf '   %s%2d) %-56s %10s B\n' "$_mark" "$_i" "$_f" "$_sz"
done
printf '   %s%2d) %-56s\n' "  " 0 "（跳过，沿用上面 ★ 标记的自动选中项）"
printf '  选择要刷入的镜像编号（0=跳过）: '
read -r _pick
case "${_pick:-0}" in
  ''|0) ok "沿用自动选中项：$REC_IMG" ;;
  *[!0-9]*) bad "输入无效"; exit 3 ;;
  *)
    _n=$((_pick-1))
    if [ "$_n" -ge 0 ] && [ "$_n" -lt ${#_opts[@]} ]; then
      _sel="${_opts[$_n]}"
      [ -f "$_sel" ] || { bad "文件不存在：$_sel"; exit 3; }
      REC_IMG="$_sel"
      REC_MD5=$(md5sum "$_sel" | cut -d' ' -f1)
      # 只改 recovery 目标；boot 刷写目标与 FNV 守卫保持自动检测的结果不变。
      # 理由：守卫由设备侧 .so 载荷读 expected_boot_sum 执行，空值行为未经验证，
      # 不能因为用户手动挑了个 recovery 镜像就连 boot 的守卫一起丢掉。
      case "$_sel" in
        *A89*|*a89*) _tag="A.89 套件" ;;
        *A92*|*a92*) _tag="A.92 套件" ;;
        recovery_原厂*) _tag="原厂 recovery（回滚用）" ;;
        *) _tag="自定义镜像" ;;
      esac
      ok "已手动指定 recovery 镜像：$_sel"
      ok "  套系     : $_tag"
      ok "  md5      : $REC_MD5"
      ok "  boot 目标: $BOOT（保持自动检测结果，未改动）"
      ok "  刷写守卫: $GUARD（保持自动检测结果，未改动）"
    else
      bad "编号超出范围（1..${#_opts[@]}）"; exit 3
    fi
    ;;
esac
# 覆盖 auto_root.sh 传给 rc17_hunt_v2.sh 的值（下游靠 export 读取）
export REC_IMG REC_MD5 BOOT BOOT_MD5 GUARD

# ============ 阶段 2：幂等预置（App / v7 目标 / 三件套 / magiskpolicy / 证据） ============
hr; echo "[2/4] 预置检查（幂等，已就位的自动跳过）"
# 2.1 当前 root 状态
RD=$(D shell 'getprop ro.debuggable' 2>/dev/null | tr -d '\r')
if [ "$RD" = "1" ]; then
  echo "  ⚠ 当前 boot 已是永久 root（ro.debuggable=1）：磨机仍可跑出 Permissive 窗口，"
  echo "    但守卫不会刷写（非原厂）。自动继续。"
fi
# 2.2 陈旧命中证据（上一轮命中的证据按设计不清空，会让新一轮立刻停机）
STALE=""
[ -n "$(D shell 'test -s /data/local/tmp/root_proof.txt && echo yes' 2>/dev/null | tr -d '\r')" ] && STALE="root_proof.txt 非空"
[ -n "$(D shell 'grep -q ROOTED /data/local/tmp/zzq1.log 2>/dev/null && echo yes' 2>/dev/null | tr -d '\r')" ] && STALE="${STALE:+$STALE + }zzq1.log 含 ROOTED"
if [ -n "$STALE" ]; then
  echo "  ⚠ 发现上一轮命中的证据（$STALE）→ 自动清空以继续新磨机。"
  bash "$HUNT" reset | sed 's/^/    /'
fi
# 2.3 载体 App
P=$(D shell 'pm path com.gc.p2' 2>/dev/null | tr -d '\r' | grep 'package:' | head -1 | sed 's/^package://')
if [ -n "$P" ]; then
  LIB="${P%/base.apk}/lib/arm/libp2probe.so"
  LM=$(D shell "md5sum $LIB" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  [ "$LM" = "$APP_MD5" ] && ok "载体 App 已安装且载荷校验一致" || { bad "载体 App 版本不符（设备 $LM）—— 重装"; D install -r ea0.apk >/dev/null 2>&1 || { bad "安装失败"; exit 3; }; }
else
  echo "  载体 App 未安装 → 安装 ea0.apk …"
  OUT=$(D install -r ea0.apk 2>&1 | tr -d '\r' | tail -1)
  case "$OUT" in
    *Success*) ok "载体 App 安装成功";;
    *INCOMPATIBLE*)
      echo "  ⚠ 签名冲突（表上有签名不同的同名 App）→ 自动卸载后重装 ea0.apk"
      D uninstall com.gc.p2 >/dev/null 2>&1
      OUT2=$(D install -r ea0.apk 2>&1 | tr -d '
' | tail -1)
      case "$OUT2" in
        *Success*) ok "已自动卸载并重装载体 App";;
        *) bad "自动重装失败: $OUT2"; exit 3;;
      esac;;
    *) bad "安装失败: $OUT"; exit 3;;
  esac
fi
# 2.4 v7 刷写目标（设备侧文件名固定为 boot_debuggable_v2.img —— .so 的 flash_guarded 按此名读取）
D push "$BOOT" /data/local/tmp/boot_debuggable_v2.img >/dev/null 2>&1
IM=$(D shell 'md5sum /data/local/tmp/boot_debuggable_v2.img' 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
[ "$IM" = "$BOOT_MD5" ] && ok "v7 刷写目标就位（$BOOT，md5 一致）" || { bad "v7 目标 md5 不符（$IM != $BOOT_MD5）"; exit 3; }
# 2.4b v7 策略工具（开机钩子依赖：/data/local/tmp/magiskpolicy）
D push magiskpolicy_arm32 /data/local/tmp/magiskpolicy >/dev/null 2>&1
D shell chmod 755 /data/local/tmp/magiskpolicy >/dev/null 2>&1
MM=$(D shell 'md5sum /data/local/tmp/magiskpolicy' 2>/dev/null | cut -c1-32)
[ "$MM" = "bfeaa0843da89d4038e1432ed3412195" ] && ok "v7 策略工具已就位（magiskpolicy，md5 一致）" || { bad "magiskpolicy 预置失败（$MM）"; exit 3; }
# 2.5 三件套（旧文件可能是历次窗口的 root 属主 → 删除重建）
D shell 'rm -f /data/local/tmp/flash_action /data/local/tmp/expected_boot_sum /data/local/tmp/flash_stage.txt' >/dev/null 2>&1
D shell "printf 'flash_guarded\n' > /data/local/tmp/flash_action; printf '$GUARD\n' > /data/local/tmp/expected_boot_sum; : > /data/local/tmp/flash_stage.txt; chmod 666 /data/local/tmp/flash_action /data/local/tmp/expected_boot_sum /data/local/tmp/flash_stage.txt" >/dev/null 2>&1
ACT=$(D shell 'md5sum /data/local/tmp/flash_action' 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
[ "$ACT" = "2b8cd0c227c19e07f4106a3c1834898b" ] && ok "刷写三件套就位（flash_guarded / 原厂 FNV 守卫）" || { bad "三件套写入失败"; exit 3; }
# 2.6 维护 recovery 镜像（磨机命中后自动刷入对应版本的 TWRP v8，缺了会静默跳过 → 这里提前把关）
[ -f "$REC_IMG" ] || { bad "缺少 $REC_IMG —— 命中后无法自动刷维护 recovery"; exit 3; }
RM2=$(md5sum "$REC_IMG" | cut -d' ' -f1)
[ "$RM2" = "$REC_MD5" ] && ok "维护 recovery 镜像就位（$REC_IMG，md5 一致）" || { bad "recovery 镜像 md5 不符（$RM2 != $REC_MD5）"; exit 3; }

# ============ 阶段 3：启动磨机（后台）+ 阶段 4：实时回报 ============
hr; echo "[3/4] 启动磨机（后台运行，本窗口实时回报状态）"
: > "$HUNT_LOG"
bash "$HUNT" > "$HUNT_LOG" 2>&1 &
HUNT_PID=$!
trap 'kill "$HUNT_PID" 2>/dev/null; exit 130' INT TERM
ok "磨机已启动（pid $HUNT_PID，日志 $HUNT_LOG）。Ctrl+C 停止。"
echo "[4/4] 实时状态回报（每 30 秒；命中/刷写开始/刷写完成会单独高亮）"
hr

last_size=0; grew=0; uid0_seen=0; flash_on=0; last_enf=""
while kill -0 "$HUNT_PID" 2>/dev/null; do
  sleep 30
  rounds=$(grep -ac "##### RC17 BOOT" rc17_log.txt 2>/dev/null)
  hb=$(tail -1 rc17_heartbeat.txt 2>/dev/null)
  # 命中检测（磨机日志的五通道结果）
  if [ "$uid0_seen" = 0 ] && grep -q "UID0 ACHIEVED" rc17_log.txt 2>/dev/null; then
    uid0_seen=1
    echo ""
    echo "  ★★★ 命中！uid=0 已达成（App 在窗口内，正在执行刷写流程）★★★"
    echo ""
  fi
  # 刷写检测：flash_stage.txt 尺寸变化 = 窗口内刷写进行中；随后趋稳 = 完成
  fs=$(D shell 'wc -c < /data/local/tmp/flash_stage.txt 2>/dev/null' | tr -d ' \r')
  case "${fs:-}" in ''|*[!0-9]*) fs="";; esac
  if [ -n "$fs" ] && [ "$fs" -gt "$last_size" ] 2>/dev/null; then
    if [ "$flash_on" = 0 ]; then
      echo "  🔧 检测到窗口内【刷写开始】（flash_stage ${last_size} → ${fs} B）"
      flash_on=1; grew=0
    fi
    last_size=$fs; grew=0
  elif [ "$flash_on" = 1 ] && [ -n "$fs" ] && [ "$fs" = "$last_size" ]; then
    grew=$((grew+1))
    [ $grew -ge 2 ] && { echo "  ✅ 【刷写完成】（flash_stage ${fs} B 已趋稳）—— 设备即将复位进 v7"; flash_on=0; }
  fi
  # SELinux 状态变化
  enf=$(D shell 'getenforce 2>/dev/null' | tr -d '\r')
  [ -n "$enf" ] && [ "$enf" != "$last_enf" ] && { [ "$enf" = "Permissive" ] && echo "  ⚡ Permissive 窗口开启（命中征兆，持续数秒~数十秒）"; last_enf="$enf"; }
  # 定期获取手表端日志（每 2 个轮询 = ~60s 拉一次最近一条 App 日志）
  p2=$(timeout 40 adb -s "$SER" shell 'logcat -d -t 5 -s P2PROBE:V 2>/dev/null | grep -v ^--------- | tail -1' 2>/dev/null | tr -d '\r' | cut -c1-110)
  printf '[%s] 运行中 第%s轮 | %s | enforce=%s | flash_stage=%s B\n   手表日志: %s\n' \
    "$(date +%H:%M:%S)" "${rounds:-0}" "${hb:-…}" "${enf:-?}" "${fs:-?}" "${p2:-（本分钟无 P2PROBE 日志，或设备复位中）}"
done
wait "$HUNT_PID"; RC=$?

# ============ 收尾 ============
hr; echo "[结束] 磨机退出（code=$RC）"
if [ "$uid0_seen" = 1 ]; then
  echo "  ✅ uid=0 已达成，已自动刷入 $BOOT（$PROFILE 套件）并复位。"
  echo "  验证: adb -s $SER shell 'id; getprop ro.debuggable; getprop service.adb.tcp.port'"
  echo "  无线: adb shell ip -4 addr show wlan0 拿 IP → adb connect <IP>:5555"
  echo "  证据: 当前目录 root_proof_* / zzq1_log_* / root_proof_cache_*"
  exit 0
fi
echo "  本轮未命中（$rounds 轮）。重跑本脚本即可继续；所有预置都在表上，无需重做 §2。"
echo "  若磨机日志显示异常，把 $HUNT_LOG 和 rc17_log.txt 发给协助者。"
exit 2
