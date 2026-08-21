#!/bin/sh
# ============================================================
# uci-defaults-mr42-ap.sh — MR42 首次启动自动配置（无线部分）
#
# 用法：贴进 firmware-selector 的 "Script to run on first boot
#       (uci-defaults)" 输入框；或放到设备的
#       /etc/uci-defaults/99-mr42-ap 后重启（执行一次后自动删除）。
#
# 已在 OpenWrt 25.12.5 / Meraki MR42 实测。
#
# ⚠️ 核心设计：**绝不按 radioN 编号写死频段**。
#    实测发现刷新固件重新生成 /etc/config/wireless 时，PCIe 枚举顺序会变，
#    radio0/radio1 与 2.4G/5G 的对应关系可能整个对调。按编号写死会配错
#    （典型症状：5GHz 被设成 HT20，白白浪费 80MHz 能力）。
#    这里改用 **PCIe path** 判断 —— path 由硬件决定，永不改变。
# ============================================================

COUNTRY=AU          # ← 按实际所在地修改；设错在法律上违规

# MR42 的三颗射频（path 恒定）：
#   soc/1b500000.pcie/...  QCA9990  5GHz    3x3  ← 主力
#   soc/1b700000.pcie/...  QCA9990  2.4GHz  3x3
#   soc/1b900000.pcie/...  168c:0050 双频   1x1  ← 扫描射频，不开 SSID
PATH_5G='soc/1b500000.pcie'
PATH_24='soc/1b700000.pcie'
PATH_SCAN='soc/1b900000.pcie'

for radio in $(uci show wireless 2>/dev/null \
               | sed -n "s/^wireless\.\(radio[0-9]*\)=wifi-device$/\1/p"); do
    rpath=$(uci -q get "wireless.$radio.path")
    band=$(uci -q get "wireless.$radio.band")

    uci set "wireless.$radio.country=$COUNTRY"

    case "$rpath" in
        *"$PATH_SCAN"*)
            # 1x1 扫描射频：同样的每链功率，但只有一根天线，
            # 总辐射约为 3x3 主射频的 1/3。开 SSID 只会拖累漫游
            # （客户端可能被这个弱信号骗过去粘住）。
            uci set "wireless.$radio.disabled=1"
            iface=$(uci show wireless 2>/dev/null \
                    | sed -n "s/^wireless\.\([a-z_0-9]*\)\.device='$radio'$/\1/p")
            [ -n "$iface" ] && uci set "wireless.$iface.disabled=1"
            continue
            ;;
        *"$PATH_5G"*)  want_band=5g; want_ht=VHT80 ;;
        *"$PATH_24"*)  want_band=2g; want_ht=HT20  ;;
        *)
            # 未知 path（非 MR42？）→ 退回按 band 判断，仍不用编号
            case "$band" in
                5g) want_band=5g; want_ht=VHT80 ;;
                2g) want_band=2g; want_ht=HT20  ;;
                *)  continue ;;
            esac
            ;;
    esac

    uci set "wireless.$radio.band=$want_band"
    uci set "wireless.$radio.htmode=$want_ht"
    uci set "wireless.$radio.channel=auto"     # ACS 自动选信道
    uci set "wireless.$radio.cell_density=0"
    uci -q delete "wireless.$radio.disabled"

    # 对应的 wifi-iface：启用 + 打开 802.11k/v
    # （802.11v 需要 full 版 wpad；官方默认的 wpad-basic-mbedtls 没有，
    #   缺了它 dawn 只能"踢"不能"劝"，漫游体验差很多）
    for iface in $(uci show wireless 2>/dev/null \
                   | sed -n "s/^wireless\.\([a-z_0-9]*\)\.device='$radio'$/\1/p"); do
        uci -q delete "wireless.$iface.disabled"
        uci set "wireless.$iface.ieee80211k=1"          # 邻居报告
        uci set "wireless.$iface.rrm_neighbor_report=1"
        uci set "wireless.$iface.rrm_beacon_report=1"
        uci set "wireless.$iface.bss_transition=1"      # 802.11v
        uci set "wireless.$iface.wnm_sleep_mode=1"
        # SSID / 加密按需自行设置，例如：
        #   uci set "wireless.$iface.ssid=MyWiFi"
        #   uci set "wireless.$iface.encryption=sae-mixed"
        #   uci set "wireless.$iface.key=..."
    done
done

uci commit wireless

# 注：国家码要等 hostapd 真正启动才会写进 regdomain。
#     接口全 disabled 时 `iw reg get` 会一直显示默认的 US —— 不是没生效。
#     另外 `wifi reload` 不会拉起已 down 的接口（autostart=false），要用 `wifi up`。

exit 0
