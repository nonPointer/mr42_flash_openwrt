# mr42-flash — Meraki MR42/MR52 → OpenWrt 刷机资料

Cisco Meraki MR42（及 MR52）刷 OpenWrt 的**全手动**资料包：文档 + 少量跨平台工具文件。
**刻意不提供 host 端一键脚本** —— 刷机步骤以文档里的手动命令给出，你在
macOS / Linux / Windows 上都能照做；设备端命令在 busybox 里执行，与 host 平台无关。

> 已在一台 MR42 上端到端验证：免拆机刷成 OpenWrt 25.12.5，标准 ath10k 下 5G 实测
> ~500Mbps，dawn + 802.11k/v 正常。踩过的坑都写进了文档。

## 🔴 先读：ath10k-ct 会让 5G 下行腰斩

OpenWrt 官方镜像默认的 `ath10k-ct` 驱动**把 5GHz 发射锁死在 40MHz**，下行只有 ~300Mbps。
换标准 `ath10k` 后实测 ~500Mbps（+67%）。**构建固件时必须换驱动** —— 详见
[`ath10k-ct-issue.md`](ath10k-ct-issue.md)。直接刷官方镜像会踩这个坑。

## 从这里开始

| 文档 | 内容 |
|---|---|
| **[`flash-steps.md`](flash-steps.md)** | **刷机五步流程，全手动命令** —— 先读这个 |
| [`guide.md`](guide.md) | 完整刷机指南（含拆机串口后路、故障排查）；host 端示例以 macOS 为主 |
| [`packages.md`](packages.md) | 定制固件包列表（firmware-selector 网页/API），含必须的驱动替换 |
| [`ath10k-ct-issue.md`](ath10k-ct-issue.md) | ath10k-ct 40MHz 限制：症状/排查/修复/实测 |
| [`radio-config.md`](radio-config.md) | 刷完后的无线 + 哑 AP 配置（设备端 UCI 手动命令） |
| [`hardware-notes.md`](hardware-notes.md) | 射频能力/功率天花板/监管域/overlay whiteout 等实测笔记 |
| [`nand-forensics.md`](nand-forensics.md) | 原厂 NAND 逆向：代号映射、RSA 签名锁、OpenWrt 血统 |
| [`toolchain-sha256.md`](toolchain-sha256.md) | 全部文件的下载地址 + sha256 校验 |

## 工具文件（跨平台，手动调用）

| 文件 | 用途 |
|---|---|
| `tftpd3.py` | 零依赖 TFTP 服务器（Python3 stdlib）。macOS 内置 tftpd 社区实测不可用，用它。`sudo python3 tftpd3.py --dir <目录>` |
| `ubootwrite3.py` | u-boot RAM 注入（Python3；**仅拆机串口路线**用），依赖 pyserial |

> 工具链二进制（u-boot / initramfs / 固件）不入库，按 `toolchain-sha256.md` 自行下载校验。

## 两条路线

| | **免拆机（推荐）** | 拆机串口（后路） |
|---|---|---|
| 前提 | 能进诊断模式（按 reset 后蓝灯） | 诊断模式进不去时 |
| 需要 | 网线 + 静态 IP + TFTP | 额外 USB-TTL、pyserial |
| 步骤 | [`flash-steps.md`](flash-steps.md) 五步 | `guide` 第 2/4 节 + `ubootwrite3.py` |
| 状态 | ✅ 实测走通 | 未在本机验证 |

## 🔴 实测踩过的坑（都写进了文档）

1. **`mtd erase` 会冻死 NAND 控制器** —— Meraki 3.4 内核在 `part_fill_badblockstats` Oops，只能断电。用 `flash_erase`，且擦写期间**单会话**操作。
2. **u-boot 请求的 .itb 文件名不带 `meraki_mr42-`** —— 名字不匹配 → TFTP 404 → 白灯不亮。下载时按 `toolchain-sha256.md` 用正确文件名（或建个别名）。
3. **reset 按太久进 failsafe** → 无 ubusd → sysupgrade 静默失败。网络引导时早点松手；已进了就手动 `ubusd &` 或 `do_stage2`（见 `flash-steps.md` ⑤）。
4. **诊断模式与正常模式 mtd 编号不同** —— u-boot 诊断是 mtd1、initramfs 里是 mtd8；写错编号毁别的分区。
5. **`ath10k-ct` 5G 锁 40MHz** —— 构建固件时换标准 `ath10k`（`packages.md` / `ath10k-ct-issue.md`）。
6. **radioN 编号刷机后可能与频段对调** —— 配无线按 `band`/`path` 判断，别写死（`radio-config.md`）。

## 纪律

- **刷机全程断外网** —— Meraki 云可远程锁机
- **写完 u-boot → 一路做到 sysupgrade 完成**，中途只用 reset 网络引导
- **绝不删 ubi1 的 ART**（射频校准，删了 WiFi 报废）
- 拆机串口只接 TXD/RXD/GND，接 3.3V 烧板

## 来源

工具链/校验值：[clayface/openwrt-cryptid](https://github.com/clayface/openwrt-cryptid)；
流程：[OpenWrt wiki MR42](https://openwrt.org/toh/meraki/mr42) + 社区实录；
本仓库的坑与实测数据：2026-08 本机验证。
