#!/bin/bash
# =============================================================================
#  flash_partition_from_recovery.sh —— 在 recovery 里把镜像写入指定分区（主机侧，走 adb）
#
#  为什么必须在 recovery 里写：本机 Android 内即使 adbd 是 uid0 也无权读写块设备
#  （SELinux/DAC 都挡），recovery 里 uid0 adb 才有块设备权限。
#
#  用法: bash flash_partition_from_recovery.sh <img> <partition> [serial]
#        例: bash flash_partition_from_recovery.sh boot_wifiadb_v7_policy_a89.img boot
#            bash flash_partition_from_recovery.sh twrp-3.7.0_9-ow20w3-recovery_v8_A89.img recovery
#
#  安全：① 只允许 boot / recovery / misc 三个分区（其余一律拒绝，防误刷）
#        ② 写完必回读 md5 与镜像比对（按镜像实际长度读前 N 字节，支持小于分区的镜像如 TWRP）
#        ③ 不一致时明确警告并给回滚命令
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1   # Git Bash 下 adb push 的设备端路径不能被转换（踩过）
IMG=${1:?用法: flash_partition_from_recovery.sh <img> <partition> [serial]}
PART=${2:?需要分区名（boot / recovery / misc）}
SER=${3:-${RC_SERIAL:-}}
if [ -z "$SER" ]; then
  _d=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')
  _n=$(printf "%s
" "$_d" | grep -c .)
  [ "$_n" = 1 ] && SER=$(printf "%s
" "$_d" | head -1) || { echo "请指定序列号: $0 <img> <partition> [serial]" >&2; exit 4; }
fi
case "$PART" in
  boot|recovery|misc) ;;
  *) echo "✗ 拒绝写入分区 '$PART'（只允许 boot / recovery / misc）"; exit 2;;
esac
DEV=/dev/block/bootdevice/by-name/$PART
D="adb -s $SER"

[ -f "$IMG" ] || { echo "✗ 找不到镜像: $IMG"; exit 1; }
LOCAL_MD5=$(md5sum "$IMG" | cut -d' ' -f1); SIZE=$(stat -c%s "$IMG")
echo "镜像: $IMG"
echo "  大小 $SIZE B   md5 $LOCAL_MD5"
echo "  目标分区: $PART ($DEV)"

echo "=== 1) 设备检查 ==="
ST=$(timeout 10 adb -s "$SER" get-state 2>/dev/null | tr -d '\r')
[ "$ST" = "recovery" ] || { echo "✗ 需要先在 recovery 模式（当前 '$ST'）—— 先 adb -s $SER reboot recovery"; exit 1; }
echo "  已在 recovery ✓  身份: $(timeout 15 $D shell 'cat /proc/self/status 2>/dev/null | grep -m1 ^Uid' | tr -d '\r')"

echo "=== 2) 分区大小核对 ==="
DEVSZ=$(timeout 20 $D shell "blockdev --getsize64 $DEV 2>/dev/null || cat /sys/class/block/${PART}/size" | tr -d '\r')
echo "  分区大小(设备报): ${DEVSZ:-未知}"
if [ -n "${DEVSZ:-}" ] && [ "$DEVSZ" -lt "$SIZE" ] 2>/dev/null; then
  echo "✗ 镜像比分区还大，拒绝"; exit 1
fi

echo "=== 3) 写权限探针（count=0，不写字节）==="
PROBE=$(timeout 20 $D shell "dd if=/dev/null of=$DEV bs=1 count=0 2>&1" | tr -d '\r')
case "$PROBE" in *"Permission denied"*|*"Read-only"*) echo "✗ 无写权限: $PROBE"; exit 1;; esac
echo "  ✓ 可写"

echo "=== 4) 推送镜像 ==="
timeout 300 adb -s "$SER" push "$IMG" /tmp/payload.img | tail -1
DEV_MD5=$(timeout 60 $D shell 'md5sum /tmp/payload.img' | tr -d '\r' | cut -d' ' -f1)
[ "$DEV_MD5" = "$LOCAL_MD5" ] || { echo "✗ 推送后 md5 不一致（设备 $DEV_MD5）"; exit 1; }
echo "  ✓ 双端一致"

echo "=== 5) 写入 $DEV ==="
timeout 300 $D shell "dd if=/tmp/payload.img of=$DEV bs=1048576 2>&1; sync" | tail -3

echo "=== 6) 回读核对 ==="
BACK=$(timeout 300 $D shell "head -c $SIZE $DEV | md5sum" | tr -d '\r' | cut -d' ' -f1)
echo "  分区前缀 md5（前 $SIZE B）: ${BACK:-读不到}   镜像 md5: $LOCAL_MD5"
if [ "$BACK" = "$LOCAL_MD5" ]; then
  echo "=== ✓ $PART 刷写成功并已核对 ==="
  echo "  重启: adb -s $SER shell 'echo b > /proc/sysrq-trigger'（recovery 里没有 reboot 命令）"
  exit 0
else
  echo "=== ✗ 回读不一致，请立刻回滚（别重启）==="
  echo "  boot 回滚:     用原厂 boot 镜像（从官方固件包取 boot.img，注意版本要对）"
  echo "  recovery 回滚: flash_partition_from_recovery.sh <原厂 recovery 镜像> recovery"
  exit 1
fi
