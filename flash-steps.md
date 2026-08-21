# MR42 刷机五步流程（免拆机路线，全手动命令）

> 平台无关：host 端只需要「静态 IP + TFTP 服务器 + telnet/ssh 客户端」，
> 三者在 macOS / Linux / Windows 上都有。设备端命令在 busybox 里执行，与 host 无关。
> 已在一台 MR42 上端到端验证。原理详见 `guide.md`；踩过的坑见 `hardware-notes.md`。

## 前置（host 端）

1. **准备文件**：按 `toolchain-sha256.md` 下载并校验：
   - `mr42_u-boot.mbn`（clayface）
   - `openwrt-ipq806x-generic-initramfs-fit-uImage.itb`（clayface；⚠️ **不带 `meraki_mr42-`** 的名字，u-boot 只认这个）
   - 最终固件：用 https://firmware-selector.openwrt.org/ 按 `packages.md` 的包列表构建（**务必换标准 ath10k**，见 `ath10k-ct-issue.md`）
2. **静态 IP**：把接 AP 的网口设为 `192.168.1.250 / 255.255.255.0`（新 u-boot 的 serverip 硬编码为此）。
3. **TFTP 服务器**：在放着上述文件的目录启动。macOS 内置 tftpd 社区实测不可用，用本仓库 `tftpd3.py`：
   ```
   sudo python3 tftpd3.py --dir .
   ```
   （69 端口 <1024 需 root；Linux 同理，Windows 用任意 TFTP server 指向该目录。）
   保持这个窗口开着——它打印每次请求，是无串口时唯一的进度指示器。

## ① 进诊断模式

```
断电 → 按住 reset 上电 ~10s → 橙灯开始闪 → 松手 → 再按 reset 两下 → 蓝灯
```
Mac 保持 192.168.1.250，然后 `telnet 192.168.1.1` → 直接 root shell（无密码）。

> 蓝灯才算进入；橙灯不闪 = 固件太新，此路不通（见 `guide` 第 1 节）。

## ② 刷 u-boot（在诊断模式 telnet 里，逐条执行）

```sh
cd /tmp
tftp-hpa 192.168.1.250 -m binary -c get mr42_u-boot.mbn
md5sum mr42_u-boot.mbn          # 必须 0b93ddf7a18a9477620f604b5fc903e1，不对就停手
echo 1 > /sys/devices/platform/msm_nand/boot_layout
flash_erase /dev/mtd1 0 0       # ⚠️ 用 flash_erase，不要用 `mtd erase`（会 Oops 冻死 NAND 控制器）
nandwrite -pam /dev/mtd1 mr42_u-boot.mbn
echo 0 > /sys/devices/platform/msm_nand/boot_layout
```

🔴 **从这一刻起进入危险窗口**：普通重启 = 砖。只能走下一步的 reset 网络引导，一路做到 sysupgrade 完成。
🔴 **一开始就用 `flash_erase`,别用 `mtd erase`**：`mtd erase /dev/mtd1` **自身**就会死锁在坏块统计（内核 `part_fill_badblockstats` 空指针 Oops），`Ctrl+C`/`kill -9` 都无效、只能断电 —— 不是并发导致的。
🔴 设备自带的 `/etc/update_uboot.sh` **不要用**：它无错误检查、且用会崩的 `mtd erase`。

（可选回读验证：`dd if=/dev/mtd1 bs=64k count=8 | strings | grep serverip` 应看到 `serverip=192.168.1.250`。）

## ③ 引导 clayface initramfs

```
断电 → 按住 reset → 上电 → 【按住 1~2 秒就松手】
```
⚠️ **别按太久**：按住不放会让 OpenWrt 进 failsafe（无 ubus，导致 ④⑤ 的 sysupgrade 静默失败）。

新 u-boot 会向 192.168.1.250 请求 `openwrt-ipq806x-generic-initramfs-fit-uImage.itb`（约 9MB，看 tftp 窗口日志）。
**白灯常亮** = initramfs 起来了。之后走网络：`ssh root@192.168.1.1`（dropbear，首次无密码）。

> u-boot 在 ② 已持久化，所以**不需要**在 initramfs 里再写一次 mtd8。

## ④ 删 Meraki UBI 卷（在 initramfs 的 ssh 里）

不删的话刷完 overlay 只剩 ~200KB。
```sh
for v in diagnostic1 part.old storage part.safe; do ubirmvol /dev/ubi0 -N "$v"; done
ubinfo -a | grep -A1 ubi1        # 确认 ART 还在！
```
🔴 **绝不能删 ubi1 的 ART**（射频校准，删了 WiFi 报废）。

## ⑤ sysupgrade（在 initramfs 的 ssh 里）

```sh
# 先从 host 把固件传进来（scp，dropbear 已内置）：
#   scp openwrt-25.12.5-<hash>-...-squashfs-sysupgrade.bin root@192.168.1.1:/tmp/
sysupgrade -n /tmp/openwrt-25.12.5-<hash>-...-squashfs-sysupgrade.bin
```

**🔴 若刷不动（只打印 "Commencing upgrade" 后无反应）= 进了 failsafe，缺 ubusd。** 手动修复：
```sh
ubusd &                          # 起 ubusd
sleep 2; ubus list | grep '^system$'   # 确认有 system 对象
sysupgrade -n /tmp/xxx.bin        # 重试
# 仍不行 → 绕过 procd 直接调平台刷写：
export IMAGE=/tmp/xxx.bin INTERACTIVE=0 VERBOSE=1
sh /lib/upgrade/do_stage2
```

重启后 = 正式 OpenWrt，**脱离危险窗口** ✅。接着按 `radio-config.md` 配无线。

## 危险窗口小结（② → ⑤）

状态 = 「新锁装好，但屋里还没家具」：新 u-boot 已取代 Meraki 引导，NAND 里还没有它能启动的系统。
- 期间只用 reset 网络引导，不普通重启
- u-boot 写进 flash 后永久有效、断电不丢
- **只要 u-boot 完好，按住 reset 上电总能救回来**，别急着拆机

## 参考

- [OpenWrt wiki: Cisco Meraki MR42](https://openwrt.org/toh/meraki/mr42)
- [clayface/openwrt-cryptid](https://github.com/clayface/openwrt-cryptid) — u-boot + 引导 initramfs 来源
- [OpenWrt: sysupgrade / failsafe](https://openwrt.org/docs/guide-user/installation/generic.sysupgrade)
