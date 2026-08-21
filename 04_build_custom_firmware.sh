#!/bin/bash
# ============================================================
# 04_build_custom_firmware.sh
#   通过 OpenWrt ASU (Attended SysUpgrade) 服务在线构建 MR42 定制固件。
#   用法: ./04_build_custom_firmware.sh [输出目录，默认 ./toolchain]
#
#   定位: 哑 AP（dumb AP）+ 有线回程 + 多 AP 漫游。不含 mesh。
#   包清单说明见 packages.md。
#
#   为什么用定制固件而不是官方镜像 + 事后 apk add：
#     编进固件的包存放在 squashfs 只读区（压缩），几乎不占 /overlay；
#     事后 apk add 会解压到 /overlay，吃掉宝贵的可用空间。
#     实测：定制版仅比官方版大 1.3 MB，而事后装同样的包要吃掉 4+ MB overlay。
#
#   两处关键的包替换（详见 hardware_notes.md）：
#     1. kmod-ath10k-ct → kmod-ath10k（标准版）
#        ath10k-ct 会把 5GHz 发射限制在 40MHz（OpenWrt issue #8262，频谱仪实测确认），
#        表现为"上行 80MHz 满速、下行恒定 40MHz 且调制已是最高 MCS9"。
#        **必须在构建时替换**：MR42 的 device_packages 写死了 ath10k-firmware-*-ct，
#        事后 apk 替换会在下次 sysupgrade 时被覆盖回去。
#     2. 不装 irqbalance —— IPQ806x 的 ath10k 中断是 PCI-MSI，不支持改 affinity，
#        irqbalance 启动后会自行退出，是无效包。
# ============================================================
set -uo pipefail

DEST="${1:-toolchain}"
ASU=https://sysupgrade.openwrt.org
VERSION=25.12.5
TARGET=ipq806x/generic
PROFILE=meraki_mr42

mkdir -p "$DEST"
red() { printf "\033[31m%s\033[0m\n" "$*"; }
grn() { printf "\033[32m%s\033[0m\n" "$*"; }
ylw() { printf "\033[33m%s\033[0m\n" "$*"; }

REQ=$(mktemp); RESP=$(mktemp); ST=$(mktemp)
trap 'rm -f "$REQ" "$RESP" "$ST"' EXIT

cat > "$REQ" <<EOF
{
  "target": "$TARGET",
  "profile": "$PROFILE",
  "version": "$VERSION",
  "packages": [
    "luci", "luci-ssl", "luci-app-attendedsysupgrade", "owut",

    "-kmod-ath10k-ct", "kmod-ath10k",
    "-ath10k-firmware-qca9887-ct", "ath10k-firmware-qca9887",
    "-ath10k-firmware-qca99x0-ct", "ath10k-firmware-qca99x0",

    "-wpad-basic-mbedtls", "wpad-mbedtls",

    "-dnsmasq",
    "-firewall4", "-luci-app-firewall",
    "-ppp", "-ppp-mod-pppoe", "-luci-proto-ppp",
    "odhcpd-ipv6only",

    "dawn", "luci-app-dawn",

    "luci-app-statistics",
    "collectd-mod-cpu", "collectd-mod-thermal",
    "collectd-mod-interface", "collectd-mod-wireless",
    "nlbwmon", "luci-app-nlbwmon",
    "prometheus-node-exporter-lua",

    "luci-app-watchcat",
    "iperf3", "ethtool", "htop", "tcpdump"
  ]
}
EOF

echo "==> 提交构建请求 ($PROFILE / $VERSION)"
code=$(curl -sL -m 90 -X POST "$ASU/api/v1/build" \
        -H 'Content-Type: application/json' -d @"$REQ" \
        -o "$RESP" -w '%{http_code}')
hash=$(python3 -c "import json;print(json.load(open('$RESP')).get('request_hash',''))" 2>/dev/null)
[ -n "$hash" ] || { red "提交失败 (HTTP $code)"; cat "$RESP" | head -20; exit 1; }
echo "    HTTP $code  request_hash=$hash"

echo "==> 等待构建完成"
for i in $(seq 1 60); do
  curl -sL -m 30 "$ASU/api/v1/build/$hash" -o "$ST"
  st=$(python3 -c "import json;print(json.load(open('$ST')).get('status',''))" 2>/dev/null)
  case "$st" in
    200) echo; grn "    构建完成"; break ;;
    202) printf "\r    构建中... %ds" $((i*5)) ;;
    *)   echo; red "    构建失败 (status=$st)"
         python3 -c "
import json;d=json.load(open('$ST'))
print('detail:',str(d.get('detail'))[:400])
print('stderr:',str(d.get('stderr',''))[-1200:])" 2>/dev/null
         exit 1 ;;
  esac
  sleep 5
done

img=$(python3 -c "
import json;d=json.load(open('$ST'))
for i in d.get('images',[]):
    if 'sysupgrade' in i.get('name',''): print(i['name']); break" 2>/dev/null)
sha=$(python3 -c "
import json;d=json.load(open('$ST'))
for i in d.get('images',[]):
    if 'sysupgrade' in i.get('name',''): print(i.get('sha256','')); break" 2>/dev/null)
[ -n "$img" ] || { red "响应里没有 sysupgrade 镜像"; exit 1; }

echo "==> 下载 $img"
curl -sL -m 300 "$ASU/store/$hash/$img" -o "$DEST/$img" -w "    HTTP %{http_code}, %{size_download} bytes\n"

got=$(shasum -a256 "$DEST/$img" | awk '{print $1}')
if [ "$got" = "$sha" ]; then
  grn "    ✓ sha256 校验通过: $got"
else
  red "    ✗ sha256 不符"; echo "      期望 $sha"; echo "      实得 $got"; exit 1
fi

echo
grn "定制固件就绪: $DEST/$img"
cat <<NEXT

刷入方式（二选一）：
  A. 已在跑 OpenWrt   → ./03_flash_openwrt.sh 会用 toolchain/ 里的官方镜像，
                        要刷这个定制版请手动：
                        scp "$DEST/$img" root@192.168.1.1:/tmp/
                        ssh root@192.168.1.1 "sysupgrade -n /tmp/$img"
  B. 全新一台         → 01 → 02 → reset 网络引导 → 在 initramfs 里刷本镜像

⚠️ 本镜像不含 uci-defaults，刷完是空配置：
   LAN 回 192.168.1.1、无线全关、国家码回默认 US。
   刷后需手工配置（或另行构建带 uci-defaults 的版本）。

NEXT
