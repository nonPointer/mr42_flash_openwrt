# toolchain/ — 刷机用二进制文件

由 `../01_fetch_toolchain.sh` 下载并逐个 sha256 校验。
用不到或易混淆的已挪进 `_unused/`（未删除，见其中的 README.txt）。

## 刷机三步各用哪个

| 步骤 | 文件 |
|---|---|
| **② 刷 u-boot** | `mr42_u-boot.mbn` |
| **③ 网络引导 initramfs** | `openwrt-ipq806x-generic-initramfs-fit-uImage.itb` |
| **⑤ 最终固件** | `mr42-custom-latest.bin` → 标准 ath10k 定制版 |

完整流程见 `../FLASH-STEPS.md`。

## ⚠️ 为什么有两个一模一样的 .itb（硬链接）

```
openwrt-ipq806x-generic-initramfs-fit-uImage.itb              ← u-boot 实际请求的名字
openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb  ← clayface 仓库的原始名
        ↑ 同一个 inode，硬链接，只占一份 8.6M 磁盘
```

**根本原因：新 u-boot 写死的文件名和 clayface 仓库的文件名对不上。**

写进 NAND 的 u-boot 环境变量（从 flash 回读确认）：

```
fit_uimage_initramfs=openwrt-ipq806x-generic-initramfs-fit-uImage.itb
                                            ↑ 没有 meraki_mr42-
serverip=192.168.1.250
ipaddr=192.168.1.100
```

而 clayface 仓库里的文件叫 `openwrt-ipq806x-generic-**meraki_mr42-**initramfs-fit-uImage.itb`。

**名字不匹配 → TFTP 404 → 引导失败。** 没有串口时，表现只是「白灯不亮」，
几乎无法定位——本机是在按 reset 之前回读 flash 里的 u-boot 才发现的。

### 为什么两个名字都保留

- **原始名**：`../TOOLCHAIN_SHA256.md` 和 `../01_fetch_toolchain.sh` 的校验按这个名字来，与上游一致
- **u-boot 请求名**：实际引导时非它不可

直接改名的话，校验逻辑与上游文档就全对不上了。

### 为什么用硬链接而非复制或软链接

- **省 8.6M** —— 两个名字共用一份数据
- **保证一致** —— 不会出现「改了一个忘了另一个」的两份文件
- **比软链接稳** —— 移动/整理目录时软链接会断，硬链接不会

### 有没有更"正确"的解法

有：进 u-boot shell 执行 `setenv fit_uimage_initramfs ... ; saveenv` 改掉请求名。
但 **u-boot shell 只能通过串口进**，免拆机路线没有串口，所以在服务端建别名
是这条路线下唯一可行也最省事的做法。

### ⚠️ 刷 MR52 时要重建别名

两个型号的 u-boot 请求的是**同一个文件名**，不能同时伺候：

```bash
ln -f openwrt-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb \
      openwrt-ipq806x-generic-initramfs-fit-uImage.itb
```

（`../01_fetch_toolchain.sh` 跑完会打印这条提醒。）

## 关于 `mr42-custom-latest.bin`

指向 ASU 构建的定制固件的**软链接**，免得记那串哈希：

```
mr42-custom-latest.bin → openwrt-25.12.5-mr42-dumbap-kvr-nodawn-09657317.bin
```

涉及**两个不同的哈希**，别混：

- ASU 生成的原始文件名里有段 `9e6712d342d8` —— **包列表哈希**，只随包集合变化。
  改包才变；只改 first-boot 配置（uci-defaults）它不变，于是不同配置版会撞同名。
- 所以本仓库把文件重命名为 `...dumbap-kvr-nodawn-<请求哈希>.bin`，后缀 `09657317` 是
  **ASU 请求哈希**（随包*或* defaults 任一变化而变），用来区分不同配置修订。

当前 `09657317` 版 sha256：`f9ecc5f163db559cbc771568f7673f228efea5c64fba05132871fee1a9799862`
（哑 AP + 11k/v/r + 标准 ath10k + 无防火墙(`-firewall4`) + 唯一 hostname + 默认启用 wifi + OTA 更新检查；
无 steering 守护，dawn 与共享 mgmt IP 冲突已弃，详见 `../radio-config.md`）。

> 🔴 **官方原版已挪进 `_unused/`** ——
> 它带 `ath10k-ct` 驱动，5G 下行会腰斩到 300 Mbps，而且文件名和定制版极其相似，
> 同目录放着容易手滑刷错。详见 `../ATH10K-CT-ISSUE.md`。

## `mr42_u-boot.bin` vs `.mbn`

同一个 u-boot 的两种格式：

- **`.mbn`** —— 免拆机路线用，`nandwrite` 写进 NAND
- **`.bin`** —— 拆机串口路线用，`ubootwrite3.py` 经串口注入 RAM

你走免拆机路线的话，`.bin` 用不到。

## 校验

全部文件的 sha256 见 `../TOOLCHAIN_SHA256.md`（clayface 6 项）
以及 downloads.openwrt.org 的官方 `sha256sums`。
2026-08-21 全量校验通过。
