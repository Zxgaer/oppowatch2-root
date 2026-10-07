<div align="center">

# OW20W1 · One-Click Permanent Root

**OPPO Watch 2 46mm · firmware A.89 / A.92 · grinds out `uid=0` from a PC and flashes permanent root automatically**

[ **中文** ](README.md) · [ **English** ]

![version](https://img.shields.io/badge/package-v8-c94f00)
![firmware](https://img.shields.io/badge/firmware-A.89%20%7C%20A.92-2f6feb)
![status](https://img.shields.io/badge/status-on--device%20verified-3fb950)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-6a737a)

</div>

---

## What this is

One script on your PC. It repeatedly drives the carrier app's fastrpc vulnerability chain on the watch; once it hits `uid=0` it **writes the v7 boot image into the boot partition** (permanent root + wireless adb + Permissive at boot + free SELinux toggling) and puts the maintenance **TWRP v8** into the recovery partition.

- Both firmware image sets (A.89 / A.92) ship in the package; the script **detects the firmware and picks the matching set** after connecting, and stops immediately if it cannot identify it
- Every write is **verified by readback**; boot is the only critical write, and it can be rolled back from Android with a single command at any time
- TWRP is **fully decoupled from boot**: any recovery problem cannot affect normal boot

<div align="center">

⚠️ For security research on your own device only. Flashing carries risk; you are responsible for your own actions.

</div>

---

## Quick start

**Prerequisites**: OW20W1 · firmware A.89 or A.92 · **stock boot** · bootloader unlocked (`orange`) · USB debugging on and this PC's adb key authorized.

| Platform | Action |
|---|---|
| **Windows** | Unzip the **whole** folder → double-click `一键Root.bat` |
| **Linux** / **macOS** | Unzip the whole folder → `bash auto_root.sh` |

The script runs this sequence: safety confirmation → adb/device check → **already-rooted gate** → firmware detection → lets you pick a recovery image → idempotent prep (carrier app / flash target / guard trio / magiskpolicy) → runs the grind in the background with live status every 30 s → on a hit, auto-flashes **v7 boot + the TWRP you picked** and reboots.

- **A hit takes 35–45 minutes on average** (~2.2% per shot). The watch rebooting itself every 1–2 minutes is **normal** — do not unplug
- Every 25 rounds the script prompts for a **true battery cold-boot** (unplug → hold the side button 12 s to power off → boot → plug back in); a warm reboot does not help, and this one noticeably improves the hit rate
- A PC reboot or a closed window loses nothing: **just run the same script again — that IS the resume**

---

## What you get

| Capability | Mechanism |
|---|---|
| **USB adb is root** (survives reboots) | `ro.debuggable=1` + `service.adb.root=1` → adbd keeps uid=0 |
| **Wireless adb**: same Wi-Fi, no cable | `service.adb.tcp.port=5555` → adbd also listens on TCP 5555 |
| **Permissive at boot** | kernel cmdline `androidboot.selinux=permissive` |
| **Toggle SELinux at will** | init context execs `magiskpolicy --live "allow shell kernel security setenforce"` → `setenforce 1`/`0` both directions work |
| **Maintenance recovery: TWRP v8** | Touch UI + **adb also runs as uid=0** with direct block-device access; **the physical power key works for screen off/on** |
| adb enabled by default | `persist.sys.usb.config=mtp,adb` |
| Security model unchanged | `ro.adb.secure=1` kept — connections still require your PC's adb key |

> The root shell's SELinux domain is still `shell`. Raw block-device access needs `setenforce 0` — which is also the fallback that lets you flash partitions in an emergency without touching recovery.

---

## Firmware support

| Detection | Basis | Image set |
|---|---|---|
| **A.89** (built 2024-08-22) | `ro.build.display.id` contains `A.89` | `boot_wifiadb_v7_policy_a89.img` / `twrp-…_v8_A89.img` / `recovery_原厂_A89.img` |
| **A.92** (built 2025-02-12) | `ro.build.display.id` contains `A.92` | `boot_wifiadb_v7_policy_a92.img` / `twrp-…_v8_A92.img` / `recovery_原厂_A92.img` |
| Anything else | — | **the script stops** (the exploit offsets are hard-coded for these two kernels) |

- **The exploit chain itself is fully portable**: every chain-relevant symbol address is identical (all deltas 0) and the fastrpc driver code is byte-identical — the `.so` payload needs zero modification
- **Images are version-matched pairs**: boot/recovery embed their own firmware's kernel+ramdisk and **must not be cross-flashed**
- Check it yourself: `adb shell getprop ro.build.display.id`

---

## Deep dive

<details>
<summary><b>Package contents</b></summary>

| File | Purpose |
|---|---|
| `一键Root.bat` | Windows double-click entry (auto-finds Git Bash, ASCII-only) |
| `auto_root.sh` | One-click orchestrator: safety gate → adb/device → firmware detection → idempotent prep → grind → live status |
| `rc17_hunt_v2.sh` | The grind loop: reboot cycle + param injection + auto-flash on a hit + stop to preserve evidence |
| `ea0.apk` | Carrier app (`com.gc.p2`), embeds the exploit `libp2probe.so`, md5 `4af0b2c5283ab616da0a8c049f567105` |
| `zzq1` / `mod.sh` | Device-side auxiliary payloads |
| `magiskpolicy_arm32` | v7 boot-hook dependency (the script stages it at `/data/local/tmp/magiskpolicy`), md5 `bfeaa0843da89d4038e1432ed3412195` |
| `boot_wifiadb_v7_policy_a89.img` | **A.89 v7 boot** (the one-click flash target), md5 `2e06f10a58d1be0ddeef7f4ccab15ec2` |
| `boot_wifiadb_v7_policy_a92.img` | **A.92 v7 boot** (the one-click flash target), md5 `ab62f167eab2983a43bd419af600c9a3` |
| `twrp-3.7.0_9-ow20w3-recovery_v8_A89.img` | **A.89 TWRP v8**, md5 `3be551bb6199ce760ab97b69efa602b8` |
| `twrp-3.7.0_9-ow20w3-recovery_v8_A92.img` | **A.92 TWRP v8**, md5 `5baf207d746fcb6f0e2689ba833e7bdf` |
| `recovery_原厂_A89.img` / `recovery_原厂_A92.img` | Stock recovery (for rollback), md5 `521436b3…` / `d05b0d37…` |
| `flash_partition_from_recovery.sh` | Partition flasher: whitelist (boot/recovery/misc) + push verification + readback compare by image length |
| `flash_v7_after_root.sh` | Helper to re-flash/switch v7 manually (stages magiskpolicy + recovery channel + setenforce round-trip check) |

> **Image note**: the `v7` in the boot image filenames is a payload code name, not the package version — this package's boot images are identical to v7's (md5 unchanged). The TWRP images are repacked to match each firmware build (kernel and ramdisk byte-wise corresponding; do not cross-flash versions).

</details>

<details>
<summary><b>Already rooted / just want a different TWRP image (no need to run the script)</b></summary>

If the watch is already `uid=0`, the one-click script stops **before any push or partition write**, exit code **6**:

```
============================================================
   [STOP] 检测到设备已经是 root（uid=0），脚本已停止
============================================================

  序列号      : <your device>
  shell uid   : 0
  ro.debuggable: 1
  SELinux     : Permissive
```

There is no reason to grind again — it would only re-flash boot and recovery pointlessly. **To swap the TWRP image only**, use the maintenance channel:

```bash
adb -s <your device> reboot recovery
adb -s <your device> push <new recovery image> /tmp/rec.img
adb -s <your device> shell 'dd if=/tmp/rec.img of=/dev/block/bootdevice/by-name/recovery bs=4096'
```

The script also **lists every recovery image in the folder** before it starts, for you to pick from (`★` = auto-selected):

```
[1.6/4] 镜像选择（回车 = 用上面自动选中的 twrp-3.7.0_9-ow20w3-recovery_v8_A92.img）
      1) recovery_原厂_A89.img                                         67108864 B
      2) recovery_原厂_A92.img                                         67108864 B
      3) twrp-3.7.0_9-ow20w3-recovery_v8_A89.img                      23604404 B
   ★  4) twrp-3.7.0_9-ow20w3-recovery_v8_A92.img                      23604420 B
      0) （跳过，沿用上面 ★ 标记的自动选中项）
```

Use it when detection picked the wrong firmware, when you want to **roll recovery back to stock**, when you want the other firmware's images, or when you bring your own image.

> Only recovery images are listed here (`boot_wifiadb_*.img` is excluded) — a boot image picked here would be written into the recovery partition and destroy it.
>
> Picking a recovery image does **not** change the boot target or the FNV guard (the guard is executed by the device-side payload; its empty-value behaviour was never verified).
>
> The script does not hardcode a serial: it auto-selects when exactly one device is connected, and lists the choices when several are.

</details>

<details>
<summary><b>Verifying the result</b></summary>

```bash
adb shell 'id; getprop ro.debuggable; getprop service.adb.tcp.port; getenforce'
# expected: uid=0(root) / 1 / 5555 / Permissive

adb shell 'setenforce 1; getenforce; setenforce 0; getenforce'
# expected: Enforcing → Permissive (the v7 policy hook works both ways)
```

```bash
adb shell ip -4 addr show wlan0      # get the watch's IP
adb connect <IP>:5555
adb -s <IP>:5555 shell id            # uid=0(root), no cable
```

Measured on-device (A.92): recovery readback md5 byte-identical to the image, boot partition md5 unchanged before/after flashing, the physical power key toggles the screen, and `/data` `/sdcard` `/cache` all mount ext4 rw.

</details>

<details>
<summary><b>Manual mode (optional, equivalent to the one-click — for step-by-step control)</b></summary>

**1. Install the carrier app**

```bash
adb install -r ea0.apk
# If you get INSTALL_FAILED_UPDATE_INCOMPATIBLE: adb uninstall com.gc.p2, then retry
```

**2. Stage the flash target, guard and policy tool**

| Parameter | A.89 | A.92 |
|---|---|---|
| Image file | `boot_wifiadb_v7_policy_a89.img` | `boot_wifiadb_v7_policy_a92.img` |
| Image md5 | `2e06f10a58d1be0ddeef7f4ccab15ec2` | `ab62f167eab2983a43bd419af600c9a3` |
| Guard FNV (stock boot, first 1 MB) | `184546148` | `4259604844` |

```bash
# Example is A.89; for A.92 substitute the values above
MSYS_NO_PATHCONV=1 adb push boot_wifiadb_v7_policy_a89.img /data/local/tmp/boot_debuggable_v2.img
adb shell 'md5sum /data/local/tmp/boot_debuggable_v2.img'
#   must equal 2e06f10a58d1be0ddeef7f4ccab15ec2

adb shell "printf 'flash_guarded\n' > /data/local/tmp/flash_action; \
printf '184546148\n' > /data/local/tmp/expected_boot_sum; \
: > /data/local/tmp/flash_stage.txt; \
chmod 666 /data/local/tmp/flash_action /data/local/tmp/expected_boot_sum /data/local/tmp/flash_stage.txt"

# v7 boot-hook dependency (required)
MSYS_NO_PATHCONV=1 adb push magiskpolicy_arm32 /data/local/tmp/magiskpolicy
adb shell 'chmod 755 /data/local/tmp/magiskpolicy'
```

**3. Run the grind**

```bash
bash rc17_hunt_v2.sh
```

On a hit: the exploit gains `uid=0` → verifies the current boot is the **matching firmware's** stock (FNV guard) → writes v7 to the boot partition (with readback) → reboots into v7 → the grind detects the hit → **auto-flashes the TWRP** (recovery channel, readback) → reboots again.

If it "cannot enter recovery" (possible on a first-time/fresh install; harmless): v7 is already live, so just dd it from Android:
`adb shell "setenforce 0; dd if=/data/local/tmp/xxx_twrp.img of=/dev/block/bootdevice/by-name/recovery bs=1048576; sync"`

</details>

<details>
<summary><b>Interrupted? Resume / reset / roll back</b></summary>

**Resume**: the grind is a **stateless loop** — all progress lives on the watch: the carrier app, the flash target, the guard trio and the evidence files are in `/data` and `/cache`. A PC reboot / power loss / killed script loses nothing. To resume:

```bash
adb devices                        # confirm the device is online
bash rc17_hunt_v2.sh               # just run it again — that IS the resume
```

- **No hit before the interruption**: it simply continues (the round counter restarts; the hit rate is per-round, unchanged)
- **A hit actually landed** (evidence not yet collected): the first evidence guard of the new run detects it, pulls the evidence and stops — **a hit is never lost to an interruption**
- **Already hit and v7 flashed**: `adb shell getprop ro.debuggable` = `1` means root is already yours
- A stale singleton lock after a PC power loss is auto-detected and bypassed

**Reset**: hit evidence is **never cleared by design** (it is the acceptance proof), so an immediate re-run stops right away. Before grinding again: `bash rc17_hunt_v2.sh reset`.

**Maintenance channel / rollback**:

```bash
adb reboot recovery                 # TWRP comes up in ~25 s, adb runs as uid=0
```

- Use the touch UI for backup/restore/flash, or adb + `flash_partition_from_recovery.sh`
- **Roll recovery back to stock**: `bash flash_partition_from_recovery.sh recovery_原厂_A92.img recovery` (use `recovery_原厂_A89.img` on A.89)
- **Roll boot back**: flash the **stock boot image** back to boot. The stock boot is *not* in this package (size / licensing); take `boot.img` from the official firmware package — A.89 / A.92 each need their own version, **do not cross-flash**. Same command: `bash flash_partition_from_recovery.sh <stock boot.img> boot`

</details>

<details>
<summary><b>Troubleshooting</b></summary>

| Symptom | Fix |
|---|---|
| Device offline / disappears for minutes and returns | USB enumeration flap, self-heals in 30–60 s; the script waits up to 180 s |
| Watch reboots repeatedly during the grind | **Normal** (failed rounds usually end with a DSP exception → watchdog reset) |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | A same-name app with a different signature exists: `adb uninstall com.gc.p2`, then reinstall |
| `adb connect <IP>:5555` times out but USB works | The watch's Wi-Fi power-save drops the link when the screen is off; use it with the screen on / while charging |
| Cannot enter recovery | Does not affect boot (boot untouched); dd the recovery back from Android under Permissive |
| Want fastboot | Unreachable on this ABL (BCB/buttons/reason all ignored) — do not waste time |

**Hit rate**: about **2.2%** per shot, 35–45 min on average — the chain is five low-probability races in series. The dominant variable is ADSP session-pool health (when degraded, the chain reuses old sessions and produces fewer shots); a **true battery cold-boot** improves it notably, and the grind prompts for one every 25 rounds.

</details>

---

## File list

The full inventory is in [`MANIFEST.txt`](MANIFEST.txt) (size and md5 of every file).

---

## License

This project is built on [TWRP](https://github.com/teamwin/twrp) and the [Android Open Source Project](https://source.android.com/), and is licensed under the **Apache License 2.0**.

The original TWRP code is © [TeamWin](https://github.com/teamwin); the scripts, image packaging and documentation in this repository are independent contributions.

Full license text: [`LICENSE`](LICENSE).

---

<div align="center">

[ **中文** ](README.md) · [ **English** ]

<sub>OW20W1 one-click root package v8 · for research on your own device only</sub>

</div>