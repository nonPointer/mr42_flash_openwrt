# mr42-flash — Meraki MR42/MR52 → OpenWrt 刷机包（macOS arm64 适配）

MR42 刷机工具包。二进制工具链由 `01_fetch_toolchain.sh` 下载并 sha256 校验，包内不携带固件。

> **2026-08-20：免拆机路线已端到端实测走通**（未拆机、未接串口）。
> 目标机刷成 OpenWrt 25.12.5，三颗射频正常，ART 完好。
> 踩到的坑已全部写进脚本与指南。

## 🔴 先读：ath10k-ct 会让 5G 下行腰斩

OpenWrt 官方镜像默认的 `ath10k-ct` 驱动**把 MR42 的 5GHz 发射锁死在 40MHz**，
下行只有 ~300 Mbps。换标准 `ath10k` 后实测 **~500 Mbps（+67%）**。

**→ 详见 [`ATH10K-CT-ISSUE.md`](ATH10K-CT-ISSUE.md)**（症状、排查、修复、验证数据）

本目录的 `04_build_custom_firmware.sh` 与 `packages.md` 已包含该修复。
**直接刷官方镜像会踩这个坑。**

## 📋 刷机五步流程 → [`FLASH-STEPS.md`](FLASH-STEPS.md)

`① 进诊断模式 → ② 刷 u-boot → ③ 引导 clayface → ④ 删 UBI 卷 → ⑤ sysupgrade`

## 刷第二台要用的三个文件（都在 `toolchain/`）

| 用途 | 文件 |
|---|---|
| ① u-boot（诊断模式写进 mtd1） | `mr42_u-boot.mbn` |
| ② 网络引导用 initramfs | `openwrt-ipq806x-generic-initramfs-fit-uImage.itb` ⚠️ **不带 `meraki_mr42-`** 的那个 |
| ③ 最终固件 | **`mr42-custom-latest.bin`**（软链接 → 标准 ath10k 定制版） |

> ⚠️ `openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin` 是**官方原版，带 CT 驱动**，
> 仅作参照，别拿来刷。

## ⚡ 两条路线

| | **免拆机（推荐先试）** | 拆机串口 |
|---|---|---|
| 前提 | 能进诊断模式（按 reset 后蓝灯） | 诊断模式进不去时的后路 |
| 流程 | `01_fetch` → `02_flash_uboot_diagnostic` → `03_flash_openwrt` | `01_fetch` → `ubootwrite3.py` → 手动 |
| 需要 | 网线 + 静态 IP，仅此 | USB-TTL、拆机、pyserial |
| 状态 | ✅ 实测走通 | 未在本机验证 |

## 文件

| 文件 | 用途 |
|---|---|
| `guide_macos_arm64.md` | **完整刷机指南**（中文）。先读它，尤其第 8 节 |
| `01_fetch_toolchain.sh` | 下载 clayface 工具链 + OpenWrt 25.12.5 官方镜像，逐文件 sha256 校验；**并自动建好 u-boot 实际请求的 .itb 文件名别名**（见下方坑 2） |
| `02_flash_uboot_diagnostic.sh` | **免拆机刷 u-boot**（诊断模式 telnet）。含前置检查、TFTP 自测、md5 闸门、`flash_erase`、回读验证 |
| `03_flash_openwrt.sh` | **刷正式固件**。自动修复 failsafe 缺 ubus 的问题，sysupgrade 空转时回退 `do_stage2` |
| `tftpd3.py` | 零依赖 TFTP 服务器（stdlib，RFC1350+blksize）。69 端口需 sudo。**它的请求日志是无串口时唯一的进度指示器** |
| `ubootwrite3.py` | ubootwrite 的 python3 移植，**仅拆机串口路线用** |
| `serial_shell.sh` | 串口终端，**仅拆机串口路线用** |
| `TOOLCHAIN_SHA256.md` | 全部文件 sha256 校验表 + 来源 |
| `04_build_custom_firmware.sh` | **调 ASU API 在线构建定制固件**（哑 AP + 漫游包集），自动轮询、下载、校验 sha256 |
| `uci-defaults-mr42-ap.sh` | **首次启动自动配无线**（国家码/信道/带宽/802.11k+v/禁用扫描射频）。**按 PCIe path 判断，不按 radioN 编号**——编号刷机后会变 |
| `packages.md` | **定制固件包清单** —— 哑 AP + 有线回程 + 漫游，分组说明与一行版，含各包所在 feed |
| `NAND-FORENSICS.md` | **原厂 NAND 固件挖掘笔记** —— Meraki 内部代号、LED/I2C 硬件真相、分区结构 |
| `FLASH-STEPS.md` | **刷机五步流程速查** —— 流程图、对应脚本、易漏点、危险窗口 |
| `ATH10K-CT-ISSUE.md` | 🔴 **ath10k-ct 的 5G 40MHz 限制** —— 症状/排查/修复/实测数据。刷机前必读 |
| `hardware_notes.md` | **MR42 射频硬件实测笔记** —— 三颗 radio 的真实能力/Tx-Power、LuCI radioN 对应关系、部署建议、reset 按钮双重行为 |

## 免拆机流程（3 条命令）

```bash
./01_fetch_toolchain.sh                              # 下载 + 校验 + 建文件名别名
cd toolchain && sudo python3 ../tftpd3.py --dir .    # 另开窗口，保持运行
# AP 进诊断模式（按住 reset 上电 ~10s → 松手 → 连按两次 → 蓝灯），Mac 网口设 192.168.1.250
./02_flash_uboot_diagnostic.sh                       # 写 u-boot（不可逆，脚本会二次确认）
# 断电 → 按住 reset → 上电 → 【按住 1~2 秒就松手】→ 等白灯常亮
./03_flash_openwrt.sh                                # 刷 25.12.5，完成
```

## 🔴 实测踩过的坑（脚本已全部处理）

1. **`mtd erase` 会冻死 NAND 控制器** — Meraki 3.4 内核在 `part_fill_badblockstats` Oops，
   进程卡 D 状态握着 NAND 锁，用户态无法解锁，**只能断电**。
   → 用 `flash_erase`；且**擦写期间只能有一个会话碰 NAND**（并发是触发条件）。
2. **u-boot 请求的 .itb 文件名与仓库里的不一样** — 实际请求
   `openwrt-ipq806x-generic-initramfs-fit-uImage.itb`（**无** `meraki_mr42-`）。
   名字不匹配 → TFTP 404 → 白灯不亮，无串口时几乎无法定位。`01_fetch` 已自动建别名。
3. **reset 按太久会进 failsafe** → 没有 ubusd → **sysupgrade 静默失败**
   （只打印 "Commencing upgrade"，然后什么都没发生）。→ 网络引导时**早点松手**；
   `03_flash_openwrt.sh` 会自动起 ubusd 并在空转时回退 `do_stage2`。
4. **诊断模式与正常模式的 mtd 编号完全不同** — u-boot 在诊断模式是 `mtd1`、在 initramfs 里是 `mtd8`；
   诊断模式的 `cal` 实为正常模式的 `art`（md5 实测一致）。**写错编号会毁掉别的分区。**
5. **设备自带的 `/etc/update_uboot.sh` 不要用** — 无任何错误检查，tftp 失败也照擦，且用会崩的 `mtd erase`。
6. **不能 dd 刷固件** — rootfs 必须写成 UBI 卷，dd 到 `/dev/mtd11` 会破坏 UBI 结构（ART 就在 ubi1 上）。
   走 `nand_do_upgrade`（`do_stage2` 会调它，MR42 的 kernel 分区是 `bootkernel2`）。

## 批量刷机（多台）

- **先备份每台的 `art`/`cal` 分区** —— 含**每台唯一**的射频校准与 MAC，
  绝不能把 A 机的写进 B 机。备份脚本见 `guide` 第 10 节。
- 脚本可重复运行：每台走一遍「诊断模式 → `02` → reset 引导 → `03`」即可，
  `toolchain/` 和 tftpd3.py 一次准备、全程复用。
- 每台之间**不用改任何配置**（IP 都是 192.168.1.1/192.168.1.250）。
- 刷完多台做漫游：装 `dawn`（LuCI 能看全网客户端分布）或 `usteer`（更轻量），
  配合 hostapd 的 802.11k/v/r。注意 **25.12.5 用 `apk`，不是 `opkg`**。

## 关键纪律

- **刷机全程断外网** —— Meraki 云可远程锁机
- **写完 u-boot → 必须一路做到 sysupgrade 完成**；中途只用 reset 网络引导，普通重启 = 砖
  - u-boot 写进 flash 后**永久有效、断电不丢**；危险的是「锁换了但屋里没家具」的中间态
  - 只要 u-boot 完好，按住 reset 上电走 TFTP 引导**总能救回来**，别急着拆机
- 只接 TXD/RXD/GND（串口路线），接 3.3V 烧板
- **千万别删 ubi1 的 ART** —— 无线校准，删了 WiFi 报废

## 数据来源

- 工具链/校验值: clayface/openwrt-cryptid（wiki 官方指定）
- 流程: OpenWrt wiki MR42/MR52 + hayao0819(2024-11)/nanotech(2023-11)/Qiita(2022-08)
- 坑 1/2/3/4/5/6 与两个新脚本: 2026-08-20 本机实测
