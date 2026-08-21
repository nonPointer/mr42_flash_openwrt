# AGENTS.md — mr42-flash 目录登记

## 用途
Meraki MR42/MR52 → OpenWrt 刷机工具包（macOS arm64 适配版）。
给用户在自己 Mac 上刷机用；脚本在本仓库留存一份，交付时 zip 打包发 Telegram。

## 脚本清单与参数

| 脚本 | 参数 | 说明 |
|---|---|---|
| `01_fetch_toolchain.sh` | `[目标目录，默认 ./toolchain]` | 下载 clayface 工具链 + 官方 25.12.5 镜像，sha256 校验，失败即中止；**并建好 u-boot 实际请求的 .itb 文件名别名** |
| `02_flash_uboot_diagnostic.sh` | `[toolchain目录]` | **免拆机刷 u-boot**（诊断模式 telnet + expect）。前置检查 → TFTP 自测 → md5 闸门 → `flash_erase` → `nandwrite` → 回读验证。单会话完成 |
| `03_flash_openwrt.sh` | `[toolchain目录]` | **刷正式固件**。检测/修复 failsafe 缺 ubus，sysupgrade 空转时自动回退 `do_stage2` |
| `ubootwrite3.py` | `--write=<镜像> [--serial=<设备>] [--verbose] [--addr] [--size] [--shell]` | python3 移植的 ubootwrite 注入（原版 python2.7）。macOS 自动探测 /dev/cu.*，Linux 回落 /dev/ttyUSB*。依赖 pyserial |
| `tftpd3.py` | `[--port 69] [--dir <目录>]` | 零依赖 TFTP 只读服务器（RFC1350+blksize）。69 端口需 root/sudo |
| `serial_shell.sh` | `[<串口设备>]` | 无参=列出端口；有参=screen 打开 115200 8N1 |

## 硬件实测数据

见 `hardware-notes.md`：三颗 radio 的真实能力（radio0=5G 3x3 23dBm 主力 / radio1=2.4G 3x3 / **radio2=1x1 扫描射频，勿开 SSID**）、
5G 的 23dBm 是硬件上限（切 ch149 验证过，法规放宽也上不去）、`wifi up` 会清掉 `disabled` 标志的坑、
25.12.5 用 apk、出厂 DHCP 默认开启、reset 按钮上电/运行中行为完全不同。

## Cron / 定时任务
无（一次性交付工具包，不调度）。

## 坑 / 注意事项
- **先查 bootkernel 版本**（串口日志 `Bootkernel Meraki Build is 25-202011091102+` = xyzzy 失效，UART 软刷不可行 → NAND 编程器）——指南第 1 节
- 只接 TXD/RXD/GND；接 3.3V 烧板
- 写完 mtd8 必须先 sysupgrade 再重启，否则砖
- 刷机全程断外网（Meraki 云可远程锁机）
- TFTP 走交换机不直连（hayao0819 实测直连失败）；macOS 内置 tftp 不可用 → 用 tftpd3.py
- 原版 ubootwrite.py 是 python2.7；macOS arm64 无 python2，用 ubootwrite3.py
- MR52 跳过 mtd8 换 u-boot 步骤（MR42 only）；MR42 原厂系统里 u-boot 是 mtd1，initramfs 里是 mtd8
- **clayface initramfs 已内置全部工具**（2026-08-20 拆包实测: mtd-rw.ko/nandwrite/nanddump/ubirmvol/ubiupdatevol/LuCI/dropbear//root/mr42_u-boot.mbn）→ 指南第 5 步不需要 opkg（其 2021 软件源已死），全程可断外网
- 完整校验值表: `toolchain-sha256.md`（下载脚本内置同表）
- 详细刷机流程/故障排查: `guide.md`

## 2026-08-20 实测结论（免拆机路线端到端走通）

目标机刷成 OpenWrt 25.12.5 r33051，三射频正常，ART 完好，可用空间 51.6MB。
**全程未拆机、未接串口** —— 诊断模式 telnet 即可完成，wiki 第 5 节（initramfs 内写 mtd8）不需要。

新增实测坑（均已写进脚本+指南）：
- `mtd erase` 在 `part_fill_badblockstats` 触发内核 Oops，卡 D 状态握 NAND 锁，只能断电 → 改用 `flash_erase`，且**擦写期间禁止并发访问 NAND**（并发是触发条件）
- **u-boot 请求的 .itb 文件名不带 `meraki_mr42-`**，与 clayface 仓库文件名不符 → 必须建别名，否则 TFTP 404、白灯不亮且无从定位
- **reset 按太久进 failsafe → 无 ubusd → sysupgrade 静默失败**（只打印 "Commencing upgrade" 后无任何动作，连续三次误判为"正在刷"）→ 起 `ubusd` 或绕过 procd 直接 `do_stage2`
- 诊断模式 `cal` == 正常模式 `art`（md5 实测一致）；u-boot 诊断 `mtd1` vs initramfs `mtd8`
- 设备自带 `/etc/update_uboot.sh` 无错误检查且用会崩的 `mtd erase`，不要用
- 不能 dd 刷固件（rootfs 须为 UBI 卷）；MR42 kernel 分区是 `bootkernel2`
- busybox 精简版无 `setsid`/`nohup`；`nc` 不支持 `-w`；`start-stop-daemon` 按 exec 名去重

用户环境：有**多台** MR42。批量刷机时每台的 `art`/`cal` 含唯一 MAC 与射频校准，**必须逐台单独备份，不可混用**。
25.12.5 的包管理器是 **apk**（非 opkg）。

## 交付记录
- 2026-08-20: 创建。用户 macOS arm64，索要 MR42 指南+脚本。zip 交付。
- 2026-08-20: 免拆机路线实测走通；新增 `02_flash_uboot_diagnostic.sh` / `03_flash_openwrt.sh`，
  重写指南第 8 节，补充故障排查表 6 条，`01_fetch_toolchain.sh` 增加 .itb 文件名别名。
