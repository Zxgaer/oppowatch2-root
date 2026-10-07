#!/bin/bash
# =============================================================================
# flash_v7_after_root.sh —— 已永久 root 的设备上，把 boot 重刷/切换为 v7 的一键脚本
#
#   v7 = permissive cmdline + init.rc 策略钩子：开机完成时以 init 上下文执行
#        /data/local/tmp/magiskpolicy --live "allow shell kernel security setenforce"
#   本脚本流程（全程带守卫，任一步失败都会安全停下并说明）：
#     0) 等设备上线（最长 5 分钟）
#     1) 守卫：必须已永久 root（ro.debuggable=1）；按固件版本选 v7 文件并核 md5
#     2) staging magiskpolicy_arm32 -> /data/local/tmp/magiskpolicy（0755，核 md5）
#     3) adb reboot recovery 并等待
#     4) 用 flash_partition_from_recovery.sh 刷 v7（白名单+推送校验+整分区回读）
#     5) sysrq 重启回 Android 并等待
#     6) 验证：ro.debuggable / getenforce / 钩子文件
#     7) 策略钩子生效性检查：setenforce 1 再 setenforce 0 往返（0 成功 = 钩子已加载）
#
#   用法: bash flash_v7_after_root.sh [serial]   （省略则自动取唯一在线设备）
#   回滚: 进 recovery 刷回原厂 boot 镜像（从官方固件包取 boot.img，注意版本要对）
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1
cd "$(cd "$(dirname "$0")" && pwd)" || exit 3
SER="${1:-${RC_SERIAL:-}}"
if [ -z "$SER" ]; then
  _d=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')
  _n=$(printf "%s
" "$_d" | grep -c .)
  [ "$_n" = 1 ] && SER=$(printf "%s
" "$_d" | head -1) || { echo "请指定序列号" >&2; exit 4; }
fi
D(){ timeout 20 adb -s "$SER" "$@" </dev/null; }
say(){ printf '\n=== %s ===\n' "$*"; }
ok(){ printf '  ✓ %s\n' "$*"; }
bad(){ printf '  ✗ %s\n' "$*"; }

say "0) 等待设备在线（$SER）"
okdev=0
for i in $(seq 1 60); do
  [ "$(timeout 10 adb -s "$SER" get-state 2>/dev/null | tr -d '\r')" = "device" ] && { okdev=1; break; }
  sleep 5
done
[ "$okdev" = 1 ] || { bad "设备未在 5 分钟内上线"; exit 4; }
ok "设备在线"

say "1) root 与固件守卫"
RD=$(D shell getprop ro.debuggable | tr -d '\r')
[ "$RD" = "1" ] || { bad "尚未永久 root（ro.debuggable=${RD:-?}）——请先完成一键 root（ro.debuggable=1）后再跑本脚本"; exit 3; }
VER=$(D shell getprop ro.build.display.id | tr -d '\r')
case "$VER" in
  *A.89*) V7="boot_wifiadb_v7_policy_a89.img"; WANT="2e06f10a58d1be0ddeef7f4ccab15ec2";;
  *A.92*) V7="boot_wifiadb_v7_policy_a92.img"; WANT="ab62f167eab2983a43bd419af600c9a3";;
  *) bad "无法识别固件版本（'${VER:-?}'）——本脚本只认 A.89/A.92"; exit 3;;
esac
[ -f "$V7" ] || { bad "缺少 $V7"; exit 3; }
GOT=$(md5sum "$V7" | cut -d' ' -f1)
[ "$GOT" = "$WANT" ] || { bad "$V7 md5 不符（$GOT != $WANT）"; exit 3; }
ok "固件 $VER → 镜像 $V7（md5 一致）"

say "2) staging magiskpolicy -> /data/local/tmp/magiskpolicy"
D push magiskpolicy_arm32 /data/local/tmp/magiskpolicy >/dev/null 2>&1
D shell chmod 755 /data/local/tmp/magiskpolicy >/dev/null 2>&1
M=$(D shell md5sum /data/local/tmp/magiskpolicy 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
[ "$M" = "bfeaa0843da89d4038e1432ed3412195" ] || { bad "staging 失败（设备侧 md5=${M:-读不到}）"; exit 3; }
ok "magiskpolicy 就位：$(D shell 'ls -l /data/local/tmp/magiskpolicy' | tr -d '\r' | awk '{print $1, $NF}')"

say "3) 重启进 recovery"
D reboot recovery >/dev/null 2>&1
okrec=0
for i in $(seq 1 60); do
  [ "$(timeout 10 adb -s "$SER" get-state 2>/dev/null | tr -d '\r')" = "recovery" ] && { okrec=1; break; }
  sleep 3
done
[ "$okrec" = 1 ] || { bad "未能进入 recovery（无损）。可手动 adb -s $SER reboot recovery 后重跑本脚本"; exit 4; }
ok "已在 recovery"

say "4) 刷入 v7（推送校验 + 整分区回读）"
bash flash_partition_from_recovery.sh "$V7" boot "$SER" || { bad "刷写未确认成功（设备仍在 recovery，可直接重试或回滚）"; exit 1; }

say "5) 重启回 Android"
timeout 20 adb -s "$SER" shell 'echo b > /proc/sysrq-trigger' >/dev/null 2>&1
okand=0
for i in $(seq 1 90); do
  [ "$(timeout 10 adb -s "$SER" get-state 2>/dev/null | tr -d '\r')" = "device" ] && { okand=1; break; }
  sleep 5
done
[ "$okand" = 1 ] || { bad "等待 Android 上线超时——请观察设备；如需回滚，进 recovery 刷回原厂 boot（见本脚本头注释）"; exit 2; }
ok "Android 已上线"

say "6) 验证"
sleep 20
echo "  ro.debuggable        = $(D shell getprop ro.debuggable | tr -d '\r')  (期望 1)"
echo "  service.adb.tcp.port = $(D shell getprop service.adb.tcp.port | tr -d '\r')  (期望 5555)"
echo "  getenforce           = $(D shell getenforce | tr -d '\r')  (v7 标称 permissive)"
echo "  钩子文件             = $(D shell 'ls -l /data/local/tmp/magiskpolicy 2>/dev/null | awk "{print \$1, \$5}"' | tr -d '\r')"

say "7) 策略钩子生效性检查（setenforce 1 → setenforce 0 往返）"
roundtrip=0
for i in $(seq 1 12); do
  D shell 'setenforce 1' >/dev/null 2>&1
  E1=$(D shell getenforce | tr -d '\r')
  if [ "$E1" = "Enforcing" ]; then
    D shell 'setenforce 0' >/dev/null 2>&1
    E2=$(D shell getenforce | tr -d '\r')
    if [ "$E2" = "Permissive" ]; then
      ok "往返成功：shell 可自由切换 SELinux（策略钩子已生效）"
      roundtrip=1
      break
    fi
    bad "setenforce 0 被拒（Enforcing 下 shell 无权限）——钩子未生效"
    bad "可能原因：boot_completed 未到 / /data/local/tmp/magiskpolicy 缺失；已尝试多次"
    # 尝试恢复：重启即回 permissive（v7 的 cmdline 每次开机生效）
    break
  fi
  sleep 10
done
[ "$roundtrip" = 1 ] || printf '  [note] 若刚开机请等 1-2 分钟钩子触发后再试；仍不行则为钩子未加载\n'

printf '\n[完成] v7 流程结束。回滚随时可用：进 recovery 刷回原厂 boot 镜像\n'
exit 0
