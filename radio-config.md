# 无线配置（哑 AP + 漫游）— 手动命令

刷完 OpenWrt 后在设备上执行（SSH 或串口进去，busybox ash，平台无关）。
这些是纯 UCI 命令，可整段粘贴，也可逐条理解后执行。

## 哑 AP 首启默认（贴进 firmware-selector 的 first-boot 框）

单网口设备物理上当不了路由器，**唯一合理角色就是哑 AP** —— 所以别用 OpenWrt 的
路由器默认（静态 192.168.1.1 + 开 DHCP server）。把下面这段贴进 firmware-selector 的
"Script to run on first boot (uci-defaults)" 框，刷完开机即是哑 AP：

```sh
#!/bin/sh
# 哑 AP 默认：lan=DHCP 客户端 + 固定 mgmt 恢复 IP + 关 DHCP 服务
MGMT_IP='192.168.1.1'                             # ← 改这里即可换 mgmt 恢复地址
MGMT_MASK='255.255.255.0'

uci set network.lan.proto='dhcp'                 # 从主网络自动拿地址（上网/NTP/OTA）

uci set network.mgmt='interface'                 # 同一 L2 的静态别名 = 带外管理入口
uci set network.mgmt.device='@lan'
uci set network.mgmt.proto='static'
uci set network.mgmt.ipaddr="$MGMT_IP"           # 固定，永远可达（主路由挂了也在）
uci set network.mgmt.netmask="$MGMT_MASK"
# 注意：mgmt 不配 gateway，默认路由只由 lan(dhcp) 那条给

uci set dhcp.lan.ignore='1'                       # 关掉发地址，别和主路由抢
uci set prometheus-node-exporter-lua.main.listen_interface='lan'   # exporter 默认绑 loopback，改 lan 才可被抓
uci set attendedsysupgrade.client.login_check_for_upgrades='1'      # 登录 LuCI 时检查固件更新（本就是默认，显式固化）
uci commit
exit 0
```

- **日常**：走 lan 拿到的 DHCP 地址（在主路由客户端列表里找，或看它的主机名）
- **救援**：笔记本设 `192.168.1.250`，直连 AP，`ssh root@192.168.1.1` —— 和刷机同一套，主网络怎样都能进
- **多台可共用同一个 mgmt IP**：只要主 LAN 不是 `192.168.1.0/24`，这个地址平时不承载任何流量、
  只在直连救援时用（那时一次只插一台），所以多台共用 `192.168.1.1` 无所谓；日常各台走各自 DHCP 地址
- **国家码/信道/SSID 不放进首启脚本**：国家码依所在地、有法律约束，按下面的手动命令逐台设


## ⚠️ 一个必须知道的坑：radioN 编号不固定对应频段

刷新固件会重新枚举 PCIe，`radio0`/`radio1` 与 2.4G/5G 的对应关系**可能整个对调**。
**绝不要按 `radio0=5g` 写死** —— 要按 `band` 或 PCIe `path` 判断。
MR42 的 path 恒定：

| PCIe path | 射频 |
|---|---|
| `soc/1b500000.pcie/...` | QCA9990 **5GHz 3×3**（主力） |
| `soc/1b700000.pcie/...` | QCA9990 **2.4GHz 3×3** |
| `soc/1b900000.pcie/...` | `168c:0050` **1×1** 扫描射频（不开 SSID） |

## 按 band 遍历配置（推荐，整段粘贴）

```sh
COUNTRY=AU        # ← 改成你的实际所在地；设错在法律上违规

for r in $(uci show wireless | sed -n 's/^wireless\.\(radio[0-9]*\)=wifi-device$/\1/p'); do
    band=$(uci -q get wireless.$r.band)
    uci set wireless.$r.country="$COUNTRY"
    case "$band" in
        5g) uci set wireless.$r.channel='149'    # UNII-3：免 DFS、AU 下 30dBm
            uci set wireless.$r.htmode='VHT80' ;;
        2g) uci set wireless.$r.channel='auto'
            uci set wireless.$r.htmode='HT20' ;;
    esac
done

# 扫描射频（1×1）保持禁用；用 path 精确定位它
scan=$(uci show wireless | grep -B1 '1b900000' | sed -n 's/^wireless\.\(radio[0-9]*\)\.path.*/\1/p')
[ -n "$scan" ] && uci set wireless.$scan.disabled='1'

# 每个已启用 radio 的接口打开 802.11k/v（需 full 版 wpad-mbedtls）
for i in $(uci show wireless | sed -n 's/^wireless\.\([a-z_0-9]*\)\.mode=.ap.$/\1/p'); do
    uci set wireless.$i.ieee80211k='1'
    uci set wireless.$i.rrm_neighbor_report='1'
    uci set wireless.$i.rrm_beacon_report='1'
    uci set wireless.$i.bss_transition='1'      # 802.11v
    uci set wireless.$i.wnm_sleep_mode='1'
    uci set wireless.$i.ieee80211r='1'          # 802.11r 快速漫游
    uci set wireless.$i.mobility_domain='4d52'  # 全 fleet 相同的一个 4-hex
    uci set wireless.$i.ft_over_ds='1'
    uci set wireless.$i.ft_psk_generate_local='1'   # PSK 本地生成，免配 r0kh/r1kh
    # SSID / 加密按需：
    # uci set wireless.$i.ssid='MyWiFi'
    # uci set wireless.$i.encryption='sae-mixed'
    # uci set wireless.$i.key='********'
done

uci commit wireless
wifi up          # 注意：wifi reload 不会拉起已 down 的接口，要用 wifi up
```

## 哑 AP 网络（关 DHCP，接进主网络）

```sh
# 关掉 DHCP/DNS（否则和主路由抢地址）
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci commit dhcp
/etc/init.d/dnsmasq disable 2>/dev/null; /etc/init.d/dnsmasq stop 2>/dev/null
/etc/init.d/odhcpd  disable 2>/dev/null; /etc/init.d/odhcpd  stop 2>/dev/null

# 给 AP 一个主网段内的固定 IP + 网关（NTP/OTA 依赖它）
uci set network.lan.ipaddr='192.168.X.2'      # ← 改成你的规划
uci set network.lan.gateway='192.168.X.1'     # ← 主路由
uci set network.lan.dns='192.168.X.1'
uci commit network
/etc/init.d/network restart
```

> 改完 LAN IP 后，设备地址就变了，用新 IP 重新连接。

## 几个非直觉行为（实测）

- 国家码只在 hostapd 真正启动后才写进 regdomain；接口全 disabled 时 `iw reg get` 一直显示默认 `US`，不是没生效
- `wifi reload` 不会启动已 `wifi down` 的接口（`autostart=false`），必须用 `wifi up`
- **活体应用网络结构性变更（新增 alias 接口、改 proto）必须 `/etc/init.d/network restart` 或重启**；
  只 `reload` 不会把新接口拉起来（实测：加 mgmt 别名后 reload，192.168.1.1 不通；重启后才生效）。
  烤进固件首启（=干净启动）则无此问题
- `wifi up` 会清掉临时测试时设的 `disabled` 标志，测完记得检查补回
### 漫游 / 频段引导：谁负责什么（重要，常被混淆）

| 机制 | 作用 | 生效条件 |
|---|---|---|
| **dawn** | **做决定** —— 该不该切、切到哪（5G/2.4G/别的 AP） | 随固件预装并自启 |
| **802.11k** | 给客户端邻居列表 | full wpad |
| **802.11v** | AP 发 "建议你搬去 X"（BSS Transition） | full wpad |
| **802.11r** | 切换时快速重认证 | full wpad **+ WPA2/WPA3-PSK** |

- **5G↔2.4G 自动切换 = band steering = dawn + 11v**，**不是 11r**。
  前提：两频段**同一个 SSID**（本固件默认都叫 `OpenWrt`）。
  dawn 默认给 5G 更高初始分（`dawn.802_11a.initial_score=100` > `802_11g=80`），
  信号够就把客户端往 5G 引导；`dawn.global.kicking>0` 时会主动引导、必要时短暂踢下线逼其重连。
- **AP 间漫游 = dawn + 11k/v/r**。
- **11r 默认在配置里开着，但开放 SSID 下惰性**；设了 PSK 才激活，且它只加速切换、不做决定。
- ⚠️ **客户端才是最终决定者**：dawn/11v 只能建议。不支持 11v 的老设备（粘性客户端）
  只能靠 `kicking` 踢下线来逼其重选，体验不如原生配合顺滑。

- 802.11k/v/r 都需要 **full 版 `wpad-mbedtls`**（basic 版无 11v/完整 11k）。
  **11r 只有在设了 WPA2/WPA3-PSK（`encryption`+`key`）后才真正生效**；`encryption=none` 时这些项惰性存在、无害。
  全 fleet 的 `mobility_domain`、SSID、加密、密钥必须一致，FT 才能在 AP 间漫游

## 参考

- [OpenWrt: dumb AP / 网桥式 AP](https://openwrt.org/docs/guide-user/network/wifi/dumbap)
- [OpenWrt: 802.11r/k/v 快速漫游](https://openwrt.org/docs/guide-user/network/wifi/80211r)
- [OpenWrt: 别名接口（aliases）](https://openwrt.org/docs/guide-user/network/network_configuration)
- [openwrt/dawn](https://github.com/openwrt/dawn) — 客户端引导守护
