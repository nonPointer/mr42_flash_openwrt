# Bootlogs

同一台 MR42 的两份内核启动日志（`dmesg`），供对照参考。

| 文件 | 系统 | 内核 | 说明 |
|---|---|---|---|
| `oem-diagnostic-dmesg-linux3.4.103.txt` | Meraki 出厂**诊断模式**（QSDK 参考镜像） | Linux 3.4.103（2015-09） | 免拆机刷机时 telnet 进去的那个系统。非 Meraki 正常产品系统 |
| `openwrt-25.12.5-dmesg-linux6.12.txt` | OpenWrt 25.12.5（本仓库刷入的定制固件） | Linux 6.12.94（2026-06） | 标准 ath10k 驱动 |

> 诊断模式的内核 banner 是 `Qualcomm Atheros AP160 reference board` —— 这是高通参考板名，
> Meraki 直接拿来当诊断系统，几乎未裁剪。产品系统的分析见 `../nand-forensics.md`。

此外 `oops-mtd-erase-diagnostic-mode.txt` 是 `mtd erase /dev/mtd1` 在诊断模式触发的完整内核 Oops（栈转储 + backtrace）—— 说明为何刷 u-boot 一开始就要用 `flash_erase`。
