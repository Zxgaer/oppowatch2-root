<div align="center">

# OW20W1 · 一键永久 Root

**OPPO Watch 2 46mm · 固件 A.89 / A.92 · 从 PC 端磨出 `uid=0`，自动刷入永久 root**

[ **中文** ] · [ **English** ](README_en.md)

![version](https://img.shields.io/badge/package-v8-c94f00)
![firmware](https://img.shields.io/badge/firmware-A.89%20%7C%20A.92-2f6feb)
![status](https://img.shields.io/badge/status-on--device%20verified-3fb950)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-6a737a)

</div>

---

## 这是什么

在 PC 上跑一个脚本，它驱动手表上载体 App 的 fastrpc 漏洞链反复触发，命中 `uid=0` 后**自动把 v7 boot 镜像写入 boot 分区**（永久 root + 无线 adb + 开机 Permissive + SELinux 随时开关），并把维护用 **TWRP v8** 写入 recovery 分区。

- 两套固件（A.89 / A.92）镜像都在包里，**脚本连接后自动检测并选用对应套件**，识别不出直接停止
- 所有写入**都带回读校验**；boot 是唯一关键写入，且随时能从 Android 一条命令回滚
- TWRP 与 boot **完全解耦**：recovery 出任何问题都不影响正常开机

<div align="center">

⚠️ 仅用于你自己设备的安全研究。刷写有风险，后果自负。

</div>

---

## 快速开始

**前置条件**：OW20W1 · 固件 A.89 或 A.92 · **boot 为原厂** · BL 已解锁（`orange`）· USB 调试开启且本机 adb 密钥已授权。

| 平台 | 操作 |
|---|---|
| **Windows** | 解压**整个**文件夹 → 双击 `一键Root.bat` |
| **Linux** / **macOS** | 解压整个文件夹 → `bash auto_root.sh` |

脚本会自动完成：安全确认 → adb/设备检查 → **已 root 闸门** → 固件版本检测 → 让你选一次 recovery 镜像 → 幂等预置（载体 App / 刷写目标 / 守卫三件套 / magiskpolicy） → 后台磨机并每 30 秒回报状态 → 命中后自动刷 **v7 boot + 你选中的 TWRP** 并重启。

- **平均 35–45 分钟命中**（单发约 2.2%），期间手表每 1–2 分钟自动复位一次是**正常现象**，不要拔线
- 磨机第 25 轮会提示做一次**电池冷启动**（拔线 → 长按侧键 12 秒关机 → 开机 → 插回），温重启无效，强烈建议照做
- 中途断电/关窗口都不丢进度：**再跑一遍同一个脚本就是续磨**

---

## 刷进去能得到什么

| 能力 | 机制 |
|---|---|
| **USB adb 直接是 root**（重启不丢） | `ro.debuggable=1` + `service.adb.root=1` → adbd 不降权，uid=0 |
| **无线 adb**：同一 Wi-Fi 不插线 | `service.adb.tcp.port=5555` → adbd 在 USB 之外同时监听 5555 |
| **开机即 Permissive** | 内核命令行追加 `androidboot.selinux=permissive` |
| **SELinux 随时自由开关** | init 上下文执行 `magiskpolicy --live "allow shell kernel security setenforce"` → `setenforce 1`/`0` 两个方向都通 |
| **维护 recovery：TWRP v8** | 触屏 UI ＋ **adb 也是 uid=0**、可直接读写块设备；**物理电源键可正常息屏/亮屏** |
| adb 默认开启 | `persist.sys.usb.config=mtp,adb` |
| 安全模型不变 | `ro.adb.secure=1` 保留——连接仍需你的 PC 的 adb 密钥授权 |

> root shell 的 SELinux 域仍是 `shell`。直读写块设备需要 `setenforce 0`——这也是紧急时不动 recovery 就能刷分区的后路。

---

## 固件支持

| 检测结果 | 识别依据 | 镜像套件 |
|---|---|---|
| **A.89**（2024-08-22 构建） | `ro.build.display.id` 含 `A.89` | `boot_wifiadb_v7_policy_a89.img` / `twrp-3.7.0_9-ow20w3-recovery_v8_A89.img` / `recovery_原厂_A89.img` |
| **A.92**（2025-02-12 构建） | `ro.build.display.id` 含 `A.92` | `boot_wifiadb_v7_policy_a92.img` / `twrp-3.7.0_9-ow20w3-recovery_v8_A92.img` / `recovery_原厂_A92.img` |
| 其他版本 | —— | **脚本直接停止**（利用链偏移按这两版内核硬编码） |

- **利用链完全通用**：两版内核的链依赖符号地址**差值全为 0**、fastrpc 驱动代码逐字节一致，`.so` 载荷零改动
- **镜像按版本分套**：boot / recovery 内嵌各自版本的 kernel+ramdisk，**不可跨版本混刷**
- 自己确认版本：`adb shell getprop ro.build.display.id`

---

## 深入

<details>
<summary><b>包内文件清单</b></summary>

| 文件 | 用途 |
|---|---|
| `一键Root.bat` | Windows 双击入口（自动找 Git Bash，ASCII-only） |
| `auto_root.sh` | 一键编排：安全门 → adb/设备 → 固件检测 → 幂等预置 → 磨机 → 实时回报 |
| `rc17_hunt_v2.sh` | 磨机主循环：重启循环 + 注参拉起载体 App + 命中即刷即停保留证据 |
| `ea0.apk` | 载体 App（`com.gc.p2`），内含漏洞载荷 `libp2probe.so`，md5 `4af0b2c5283ab616da0a8c049f567105` |
| `zzq1` / `mod.sh` | 设备侧辅助 payload |
| `magiskpolicy_arm32` | v7 开机钩子依赖（自动放入 `/data/local/tmp/magiskpolicy`），md5 `bfeaa0843da89d4038e1432ed3412195` |
| `boot_wifiadb_v7_policy_a89.img` | **A.89 v7 boot**（一键刷写目标），md5 `2e06f10a58d1be0ddeef7f4ccab15ec2` |
| `boot_wifiadb_v7_policy_a92.img` | **A.92 v7 boot**（一键刷写目标），md5 `ab62f167eab2983a43bd419af600c9a3` |
| `twrp-3.7.0_9-ow20w3-recovery_v8_A89.img` | **A.89 TWRP v8**，md5 `3be551bb6199ce760ab97b69efa602b8` |
| `twrp-3.7.0_9-ow20w3-recovery_v8_A92.img` | **A.92 TWRP v8**，md5 `5baf207d746fcb6f0e2689ba833e7bdf` |
| `recovery_原厂_A89.img` / `recovery_原厂_A92.img` | 原厂 recovery（回滚用），md5 `521436b3…` / `d05b0d37…` |
| `flash_partition_from_recovery.sh` | 分区刷写工具：白名单（boot/recovery/misc）+ 推送校验 + 按镜像长度回读比对 |
| `flash_v7_after_root.sh` | 手动重刷/切换 v7（staging magiskpolicy + recovery 通道 + setenforce 往返检查） |

> **镜像说明**：boot 镜像文件名里的 `v7` 是载荷代号，不是包版本——本包的 boot 镜像与 v7 完全相同（md5 未变）。TWRP 镜像为按固件版本重新打包的匹配版（内核与 ramdisk 逐字节对应，勿跨版本混刷）。

</details>

<details>
<summary><b>已 root 时 / 想换 TWRP 镜像（不必再跑脚本）</b></summary>

如果设备已经是 `uid=0`，一键脚本**在任何推送或刷写之前**停下，退出码 **6**：

```
============================================================
   [STOP] 检测到设备已经是 root（uid=0），脚本已停止
============================================================

  序列号      : <你的设备>
  shell uid   : 0
  ro.debuggable: 1
  SELinux     : Permissive
```

已经拿到 root 就没必要再磨机，重复执行只会把 boot / recovery 无意义地再刷一遍。**只想换 TWRP 镜像**走维护通道即可：

```bash
adb -s <你的设备> reboot recovery
adb -s <你的设备> push <新recovery镜像> /tmp/rec.img
adb -s <你的设备> shell 'dd if=/tmp/rec.img of=/dev/block/bootdevice/by-name/recovery bs=4096'
```

一键脚本在开跑前还会**列出目录里所有 recovery 镜像**让你挑（`★` = 自动选中的）：

```
[1.6/4] 镜像选择（回车 = 用上面自动选中的 twrp-3.7.0_9-ow20w3-recovery_v8_A92.img）
      1) recovery_原厂_A89.img                                         67108864 B
      2) recovery_原厂_A92.img                                         67108864 B
      3) twrp-3.7.0_9-ow20w3-recovery_v8_A89.img                      23604404 B
   ★  4) twrp-3.7.0_9-ow20w3-recovery_v8_A92.img                      23604420 B
      0) （跳过，沿用上面 ★ 标记的自动选中项）
```

用于：自动检测认错固件版本、想刷**原厂 recovery 回滚**、想刷另一套固件的镜像、自备镜像。

> 这里**只列 recovery 镜像**（`boot_wifiadb_*.img` 被排除）——boot 镜像选到这里会被当 recovery 写进 p51，直接毁掉 recovery 分区。
>
> 手动选 recovery 镜像**不会改动** boot 刷写目标和 FNV 守卫（守卫由设备侧载荷执行，空值行为未经验证）。
>
> 脚本不写死序列号：只连一台设备时自动选中，多台设备时列出来让你选。

</details>

<details>
<summary><b>验证结果</b></summary>

```bash
adb shell 'id; getprop ro.debuggable; getprop service.adb.tcp.port; getenforce'
# 期望：uid=0(root) / 1 / 5555 / Permissive

adb shell 'setenforce 1; getenforce; setenforce 0; getenforce'
# 期望：Enforcing → Permissive（v7 策略钩子生效，两个方向都通）
```

```bash
adb shell ip -4 addr show wlan0      # 拿手表 IP
adb connect <IP>:5555
adb -s <IP>:5555 shell id            # uid=0(root)，全程不插线
```

TWRP 侧实测（A.92）：recovery 回读 md5 与镜像逐字节一致、boot 分区刷前刷后 md5 未变、物理电源键息屏亮屏正常、`/data` `/sdcard` `/cache` 全部 ext4 rw。

</details>

<details>
<summary><b>手动模式（可选，与一键等价——想逐步控制再用）</b></summary>

**1. 安装载体 App**

```bash
adb install -r ea0.apk
# 若报 INSTALL_FAILED_UPDATE_INCOMPATIBLE：adb uninstall com.gc.p2 后重试
```

**2. 预置刷写目标、守卫与策略工具**

| 参数 | A.89 | A.92 |
|---|---|---|
| 镜像文件 | `boot_wifiadb_v7_policy_a89.img` | `boot_wifiadb_v7_policy_a92.img` |
| 镜像 md5 | `2e06f10a58d1be0ddeef7f4ccab15ec2` | `ab62f167eab2983a43bd419af600c9a3` |
| 守卫 FNV（原厂 boot 前 1MB） | `184546148` | `4259604844` |

```bash
# 示例为 A.89；A.92 请替换上表对应值
MSYS_NO_PATHCONV=1 adb push boot_wifiadb_v7_policy_a89.img /data/local/tmp/boot_debuggable_v2.img
adb shell 'md5sum /data/local/tmp/boot_debuggable_v2.img'
#   必须等于 2e06f10a58d1be0ddeef7f4ccab15ec2

adb shell "printf 'flash_guarded\n' > /data/local/tmp/flash_action; \
printf '184546148\n' > /data/local/tmp/expected_boot_sum; \
: > /data/local/tmp/flash_stage.txt; \
chmod 666 /data/local/tmp/flash_action /data/local/tmp/expected_boot_sum /data/local/tmp/flash_stage.txt"

# v7 开机钩子依赖（必须）
MSYS_NO_PATHCONV=1 adb push magiskpolicy_arm32 /data/local/tmp/magiskpolicy
adb shell 'chmod 755 /data/local/tmp/magiskpolicy'
```

**3. 跑磨机**

```bash
bash rc17_hunt_v2.sh
```

命中后自动发生：exploit 取 `uid=0` → 校验当前 boot 为**对应版本原厂**（FNV 守卫）→ 把 v7 整块写入 boot（带回读比对）→ 复位启动 v7 → 磨机检测到命中 → **自动刷入 TWRP**（recovery 通道，回读校验）→ 重启。

若"未能进入 recovery"（首次全新安装时可能发生，无损）：v7 已生效，从 Android 直接补刷即可：
`adb shell "setenforce 0; dd if=/data/local/tmp/xxx_twrp.img of=/dev/block/bootdevice/by-name/recovery bs=1048576; sync"`

</details>

<details>
<summary><b>中断续磨 / 重置 / 回滚</b></summary>

**中断续磨**：磨机是**无状态循环**，所有进度都在表上——载体 App、刷写目标、守卫三件套、命中证据文件都在 `/data` 与 `/cache`，PC 重启/断电/脚本被杀都不会丢。恢复只需：

```bash
adb devices                        # 确认设备在线
bash rc17_hunt_v2.sh               # 直接重跑，即为续磨
```

- 中断前**没有命中**：直接继续（轮数计数从 1 重新开始，不影响命中率）
- 中断前**其实已命中**：重跑后第一轮的证据守卫会立刻发现它、拉取证据并停机——**命中不会因为中断而丢**
- 中断前**已命中并刷了 v7**：`adb shell getprop ro.debuggable` = `1` 即已到手
- 单例锁文件在 PC 断电后是死锁，脚本会自动识别死锁并放行

**重置**：命中证据按设计**从不清空**（那是验收凭证），紧接着再跑会立刻停机。再磨前 `bash rc17_hunt_v2.sh reset`。

**维护通道 / 回滚**：

```bash
adb reboot recovery                 # 约 25 秒进入 TWRP，adb 侧 uid=0
```

- 触屏 UI 可直接备份/恢复/刷写；adb 侧也可用 `flash_partition_from_recovery.sh`
- **回滚 recovery 到原厂**：`bash flash_partition_from_recovery.sh recovery_原厂_A92.img recovery`（A.89 用 `recovery_原厂_A89.img`）
- **回滚 boot**：把**原厂 boot 镜像**刷回 boot。原厂 boot 不在本包里（体积与版权原因），从官方固件包里取 `boot.img`——A.89 / A.92 各对应自己的版本，**不可混刷**。刷法同上：`bash flash_partition_from_recovery.sh <原厂boot.img> boot`

</details>

<details>
<summary><b>故障速查</b></summary>

| 现象 | 处置 |
|---|---|
| 设备 offline / 消失几分钟又回来 | USB 枚举抖动，30–60s 自愈；脚本已内置最长 180s 等待 |
| 磨机中反复复位 | **正常**（每轮失败多以 DSP 异常→看门狗复位收场） |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 表上有签名不同的同名 App：`adb uninstall com.gc.p2` 后重装 |
| `adb connect <IP>:5555` 超时但 USB 正常 | 手表 Wi-Fi 省电会灭屏断网；亮屏/充电时用 |
| 进不去 recovery | 不影响开机（boot 未动）；从 Android Permissive 下直接 dd 补刷 |
| 想进 fastboot | 该机 ABL 不可达（BCB/按键/reason 全被无视），别浪费时间 |

**命中率**：单发约 **2.2%**，均值 35–45 分钟——链路是五段低概率竞态的串联。关键变量是 ADSP 会话池健康度（差时回落复用旧会话、发数变少）；**真·电池冷启动**能显著改善，磨机第 25 轮会提示。

</details>

---

## 文件清单

完整清单见 [`MANIFEST.txt`](MANIFEST.txt)（含每个文件的尺寸与 md5）。

---

## 开源协议

本项目基于 [TWRP](https://github.com/teamwin/twrp) 与 [Android Open Source Project](https://source.android.com/) 构建，遵循 **Apache License 2.0**。

原始 TWRP 代码版权归 [TeamWin](https://github.com/teamwin) 所有；本仓库的脚本、镜像打包与说明文档为独立贡献。

完整协议全文见 [`LICENSE`](LICENSE)。

---

<div align="center">

[ **中文** ] · [ **English** ](README_en.md)

<sub>OW20W1_PC端提权包 v8 · 仅限自有设备研究使用</sub>

</div>