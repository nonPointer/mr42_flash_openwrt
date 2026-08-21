# MR42/MR52 工具链 sha256 校验表

> 来源: [clayface/openwrt-cryptid README](https://github.com/clayface/openwrt-cryptid)（md5+sha256 实测一致）、
> [downloads.openwrt.org 25.12.5 sha256sums](https://downloads.openwrt.org/releases/25.12.5/targets/ipq806x/generic/sha256sums)。
> 手动下载：对下表每个 URL `curl -LO <url>`（或 wget），再逐个校验：
> macOS `shasum -a256 <文件>`，Linux `sha256sum <文件>`，对照本表。任一不符不要使用。


## 手动下载（免拆机路线只需前两个 + 自建固件）

```sh
# clayface 工具（u-boot + 网络引导 initramfs）
base=https://raw.githubusercontent.com/clayface/openwrt-cryptid/main
curl -LO $base/mr42_u-boot.mbn
curl -LO $base/openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb

# u-boot 只认不带 meraki_mr42- 的文件名 → 建个别名（硬链接/复制均可）
ln openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb \
   openwrt-ipq806x-generic-initramfs-fit-uImage.itb

# 校验（macOS: shasum -a256 ; Linux: sha256sum），对照下表
shasum -a256 mr42_u-boot.mbn openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb
```

> 拆机串口路线另需 `mr42_u-boot.bin` 和 `ubootwrite.py`（同一 base）。
> 最终固件不在此下载——按 `packages.md` 用 firmware-selector 构建（**务必换标准 ath10k**）。


## clayface/openwrt-cryptid（ubootwrite 注入 + 二级 u-boot + 老 initramfs）

| 文件 | 大小 | 用途 | sha256 |
|---|---|---|---|
| `mr42_u-boot.bin` | 319,584 B | ubootwrite 串口注入 RAM 用（MR42） | `319742c4baac6a8506b0ab2fd69b2927c0ef8f6f0d96c744388101ad7f62c53b` |
| `mr42_u-boot.mbn` | 319,592 B | 刷入 NAND mtd8 的网络版 u-boot（MR42 必换，md5 `0b93ddf7a18a9477620f604b5fc903e1`） | `ac39dcfb396b2fb115d8890ff812b51c0ff608b77cd3947c4d1f99aaf855a7ac` |
| `mr52_u-boot.bin` | 326,324 B | ubootwrite 注入用（MR52） | `9fc4c85b288d0b7eb47dccb4a072219c73c2a855b4b449730f3918f5111e434c` |
| `openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb` | 9,061,040 B | TFTP 引导 initramfs（内核 5.10.35，**内含 /root/mr42_u-boot.mbn**） | `861e57593a207afbc26c2c2df2b8deb838b413af006b23e9f6142922fc9ed722` |
| `openwrt-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb` | 9,982,428 B | MR52 版 initramfs | `4cfbb851ddca8abfd231c255d56d94189144d063cec67de326571f7a0f9624e6` |
| `ubootwrite.py` | 6,763 B | 原版 python2.7 注入脚本（本包 `ubootwrite3.py` 为其 python3 移植） | `ae6f0cff7ede880876e2a40279d8fae406de6edc61cb3e6fb3bccc22f164bf5f` |

## OpenWrt 官方 25.12.5（正式刷机镜像，firmware-selector 同源）

| 文件 | 大小 | 用途 | sha256 |
|---|---|---|---|
| `openwrt-25.12.5-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb` | 10,864.8 KB | 官方 initramfs（备选；不含 .mbn，需自备） | `ab66e3a4e46d3f70fda07645d12a556259745677659207317982916b66ef0179` |
| `openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin` | 9,620.3 KB | **最终刷入的正式固件（MR42）** | `c0c4c529997552b32e62357c1cdb097ae3cd74e4d208a7bdd81c9676a7ab6967` |
| `openwrt-25.12.5-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb` | 10,903.8 KB | 官方 initramfs（MR52 备选） | `6efb1ad1f276ca976ae360bb0d775a5d4103821f4d406f382a5307dfcea183ee` |
| `openwrt-25.12.5-ipq806x-generic-meraki_mr52-squashfs-sysupgrade.bin` | 9,660.3 KB | 正式固件（MR52） | `3c316ea641fd31a2ab63292e4bda7b05c3f01c97f3da9c11b8b5ab23f0ae6ec7` |
