#!/bin/bash
# ============================================================
# 01_fetch_toolchain.sh — 下载 MR42/MR52 刷机工具链 + 官方镜像，并校验 sha256
# macOS (arm64) / Linux 通用。macOS 用内置 shasum，Linux 用 sha256sum。
# 用法: ./01_fetch_toolchain.sh [目标目录，默认 ./toolchain]
# 说明: 任一文件校验失败 → 立即中止，防止刷入被篡改的固件。
# 来源: clayface/openwrt-cryptid + downloads.openwrt.org (25.12.5)
# ============================================================
set -euo pipefail

DEST="${1:-toolchain}"
mkdir -p "$DEST"

if command -v shasum >/dev/null 2>&1; then
  HASH() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  HASH() { sha256sum "$1" | awk '{print $1}'; }
fi

# 格式: 文件名|URL|sha256
FILES=(
"ubootwrite.py|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/ubootwrite.py|ae6f0cff7ede880876e2a40279d8fae406de6edc61cb3e6fb3bccc22f164bf5f"
"mr42_u-boot.bin|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/mr42_u-boot.bin|319742c4baac6a8506b0ab2fd69b2927c0ef8f6f0d96c744388101ad7f62c53b"
"mr42_u-boot.mbn|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/mr42_u-boot.mbn|ac39dcfb396b2fb115d8890ff812b51c0ff608b77cd3947c4d1f99aaf855a7ac"
"mr52_u-boot.bin|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/mr52_u-boot.bin|9fc4c85b288d0b7eb47dccb4a072219c73c2a855b4b449730f3918f5111e434c"
"openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb|861e57593a207afbc26c2c2df2b8deb838b413af006b23e9f6142922fc9ed722"
"openwrt-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb|https://raw.githubusercontent.com/clayface/openwrt-cryptid/main/openwrt-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb|4cfbb851ddca8abfd231c255d56d94189144d063cec67de326571f7a0f9624e6"
"openwrt-25.12.5-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb|https://downloads.openwrt.org/releases/25.12.5/targets/ipq806x/generic/openwrt-25.12.5-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb|ab66e3a4e46d3f70fda07645d12a556259745677659207317982916b66ef0179"
"openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin|https://downloads.openwrt.org/releases/25.12.5/targets/ipq806x/generic/openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin|c0c4c529997552b32e62357c1cdb097ae3cd74e4d208a7bdd81c9676a7ab6967"
"openwrt-25.12.5-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb|https://downloads.openwrt.org/releases/25.12.5/targets/ipq806x/generic/openwrt-25.12.5-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb|6efb1ad1f276ca976ae360bb0d775a5d4103821f4d406f382a5307dfcea183ee"
"openwrt-25.12.5-ipq806x-generic-meraki_mr52-squashfs-sysupgrade.bin|https://downloads.openwrt.org/releases/25.12.5/targets/ipq806x/generic/openwrt-25.12.5-ipq806x-generic-meraki_mr52-squashfs-sysupgrade.bin|3c316ea641fd31a2ab63292e4bda7b05c3f01c97f3da9c11b8b5ab23f0ae6ec7"
)

ok=0
for entry in "${FILES[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  url="${rest%%|*}"; expect="${rest#*|}"
  echo "==> $name"
  curl -fsSL --retry 3 -o "$DEST/$name" "$url" || { echo "下载失败: $name"; exit 1; }
  got="$(HASH "$DEST/$name")"
  if [ "$got" != "$expect" ]; then
    echo "!! sha256 校验失败: $name"; echo "   期望 $expect"; echo "   实得 $got"; exit 1
  fi
  echo "    sha256 OK ($expect)"
  ok=$((ok+1))
done

echo
echo "全部 $ok 个文件下载并校验通过 -> $DEST"
echo "下一步: 静态 IP 192.168.1.250 -> 启动 tftpd3.py -> 按指南刷机"

# ============================================================
# 关键补丁（2026-08-20 实测）：cryptid u-boot 请求的 initramfs 文件名
# 与 clayface 仓库里的文件名不一致！
#
# 写进 NAND 的 u-boot 环境变量实际是：
#   fit_uimage_initramfs=openwrt-ipq806x-generic-initramfs-fit-uImage.itb
# 而仓库里的文件叫：
#   openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb
#
# 名字对不上 → u-boot TFTP 请求 404 → 反复重试、永远进不了 initramfs。
# 没有串口时这个故障几乎无法定位（表现只是"白灯不亮"）。
# 所以这里按 u-boot 实际请求的名字额外建一份硬链接。
# ============================================================
echo
echo "==> 建立 u-boot 实际请求的文件名别名"
for m in mr42 mr52; do
  src="$DEST/openwrt-ipq806x-generic-meraki_${m}-initramfs-fit-uImage.itb"
  dst="$DEST/openwrt-ipq806x-generic-initramfs-fit-uImage.itb"
  [ -f "$src" ] || continue
  # 两型号的目标名相同，MR42 优先；刷 MR52 时请手动重建指向 mr52 的链接
  if [ "$m" = "mr42" ]; then
    ln -f "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
    echo "    $(basename "$dst")  ->  $(basename "$src")"
  fi
done
echo
echo "⚠️  刷 MR52 时请改指向 mr52 的镜像："
echo "    ln -f $DEST/openwrt-ipq806x-generic-meraki_mr52-initramfs-fit-uImage.itb \\"
echo "          $DEST/openwrt-ipq806x-generic-initramfs-fit-uImage.itb"
echo
echo "提示：请用本包的 tftpd3.py 分发 $DEST 目录（它会打印每次请求，"
echo "      是无串口刷机时唯一的进度指示器）。"
