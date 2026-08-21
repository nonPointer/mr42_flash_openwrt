# MR42 刷机五步流程（免拆机路线，实测走通）

> 2026-08-21 在一台 Meraki MR42 上端到端验证。全程**不拆机、不接串口**。
> 完整原理见 `guide_macos_arm64.md` 第 8 节；踩过的坑见 `hardware_notes.md`。

## 总览

```
① 进诊断模式        断电 → 按住 reset 上电 ~10s → 橙灯闪 → 松手
                    → 再按 reset 两下 → 蓝灯 → telnet 192.168.1.1
                    （Mac 网口设 192.168.1.250 + 起 tftpd3.py）
                              ↓
② 刷 u-boot         tftp 取 .mbn → md5 校验 → flash_erase mtd1 → nandwrite
                    ⚠️ 从这一刻起进入危险窗口，普通重启 = 砖
                              ↓
③ 引导 clayface     断电 → 按住 reset 上电 → 【按住 1~2 秒就松手】
                    → 新 u-boot 自动 TFTP 拉 .itb → 白灯常亮
                    ⚠️ 别按太久，否则进 failsafe（无 ubus，sysupgrade 会静默失败）
                              ↓
④ 删 Meraki UBI 卷  ← 这步别忘！不删的话刷完只剩 ~200KB
                    ubirmvol /dev/ubi0 -N {diagnostic1,part.old,storage,part.safe}
                    ⚠️ 绝不能碰 ubi1 的 ART（射频校准，删了 WiFi 报废）
                              ↓
⑤ sysupgrade        刷 mr42-custom-latest.bin → 重启 → 脱离危险窗口 ✅
```

## 对应脚本

| 步骤 | 命令 |
|---|---|
| ① 前置 | `./01_fetch_toolchain.sh`<br>`cd toolchain && sudo python3 ../tftpd3.py --dir .`（另开窗口保持运行） |
| ② | `./02_flash_uboot_diagnostic.sh` |
| ③ | 手动按 reset（脚本会提示） |
| ④⑤ | `./03_flash_openwrt.sh`（含删卷 + sysupgrade + ubus 修复回退） |

## 三个最容易漏的点

**1. ② 之前必须先进诊断模式** —— 那是 telnet 唯一的来源。
按 reset 后**蓝灯**才算进入；橙灯不闪说明这台固件太新，免拆机路线走不通（见 `guide` 第 1 节）。

**2. ③ 的 clayface 只活在内存里**，断电即消失。
它的唯一作用是「提供一个能跑 sysupgrade 的环境」。别把它当最终系统
（内核是 2021 年的 5.10）。

**3. ④ 删 UBI 卷不能省。**
MR42 的 NAND 是 128MB，不删 Meraki 系统卷的话刷完 overlay 只剩 ~200KB，
什么都装不了。删掉后可用空间约 **51.6MB**（实测值）。

## 危险窗口：② → ⑤ 之间

这期间的状态是「**新锁已装好，但屋里还没家具**」——
新 u-boot 已经取代了 Meraki 的引导，但 NAND 里还没有它能启动的 OpenWrt。

- 期间**只能用 reset 网络引导**，不能普通重启
- **u-boot 写进 flash 后是永久的、断电不丢** —— 这点很重要
- 所以**只要 u-boot 完好，按住 reset 上电总能救回来**，别急着拆机

> 实测佐证：本机曾在 ② 之前遭遇 `mtd erase` 触发内核 Oops、NAND 控制器冻死，
> 断电重启后回读确认 u-boot 完好无损，设备正常回到诊断模式。

## 要用的三个文件（都在 `toolchain/`）

| 步骤 | 文件 |
|---|---|
| ② | `mr42_u-boot.mbn` |
| ③ | `openwrt-ipq806x-generic-initramfs-fit-uImage.itb` ⚠️ **不带 `meraki_mr42-`** 的那个（新 u-boot 只认这个名字） |
| ⑤ | `mr42-custom-latest.bin`（软链接 → 标准 ath10k 定制版） |

⚠️ **别刷** `openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin` ——
那是官方原版，带 ath10k-ct 驱动，5G 下行会腰斩到 300 Mbps。详见 `ATH10K-CT-ISSUE.md`。

## 全程纪律

- **断外网** —— Meraki 云可远程锁机
- **擦写 NAND 期间只能有一个会话操作** —— 并发访问会触发内核 Oops 冻死控制器
- **绝不碰 ubi1 的 ART**
