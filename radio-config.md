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

# 唯一 hostname —— 多 AP 部署时日志/DHCP 客户端列表/SSH 靠它区分；从 eth0 MAC 自动派生，一份镜像刷所有设备
_mac=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
[ -n "$_mac" ] && uci set system.@system[0].hostname="mr42-$(echo -n "$_mac" | tail -c 6)"

uci set network.lan.proto='dhcp'                 # 从主网络自动拿地址（上网/NTP/OTA）

uci set network.mgmt='interface'                 # 同一 L2 的静态别名 = 带外管理入口
uci set network.mgmt.device='br-lan'   # 直接绑桥设备，不用 @lan 别名（见下）
uci set network.mgmt.proto='static'
uci set network.mgmt.ipaddr="$MGMT_IP"           # 固定，永远可达（主路由挂了也在）
uci set network.mgmt.netmask="$MGMT_MASK"
# 注意：mgmt 不配 gateway，默认路由只由 lan(dhcp) 那条给

uci set dhcp.lan.ignore='1'                       # 关掉发地址，别和主路由抢
uci set prometheus-node-exporter-lua.main.listen_interface='lan'   # exporter 默认绑 loopback，改 lan 才可被抓
uci set attendedsysupgrade.client.login_check_for_upgrades='1'      # 登录 LuCI 时检查固件更新（本就是默认，显式固化）

# 哑 AP 不需要防火墙：只做 L2 桥接，过路流量走网桥不经 fw4；fw4 只挡到达本机的流量，而本机管理在可信 LAN 上本就放行。
# 关键：默认 input=REJECT（对 TCP 发 tcp-reset），lan 无 DHCP 租约时 br-lan 会掉出 lan zone → 本该救援的 mgmt IP 反被 REJECT。见下"必须知道的坑"。
/etc/init.d/firewall disable 2>/dev/null; /etc/init.d/firewall stop 2>/dev/null

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
    uci -q delete wireless.$i.disabled          # 启用接口（OpenWrt 默认全 disabled='1'）；生产应先设 SSID+密码
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
- 🔴 **mgmt 恢复 IP 必须绑 `br-lan`，不能用 `@lan` 别名**：alias 依赖 parent 接口 up，而 `proto=dhcp`
  的 lan 在**拿到租约前不算 up**；en7 直连（无 DHCP server）时 lan 永远不 up → `@lan` 别名不生效 →
  连不上 —— 恰恰在最需要救援 IP 时失效。绑 `br-lan` 随链路 up 即生效，与 DHCP 无关。
- 🔴 **哑 AP 要关防火墙，否则无 DHCP 租约时 mgmt 救援 IP 被 tcp-reset**：默认 `input=REJECT`（对 TCP 回 RST）。
  lan 是 `proto=dhcp`，无租约时不 up，fw4 便不把 br-lan 归入 lan zone → br-lan 落默认 REJECT → 挂在 br-lan 上的
  mgmt IP 连 22/80 全被 RST。正好在"网络挂了要救援"时失效。哑 AP 本不需要 fw4（只 L2 桥接、过路流量不经它），
  直接 `/etc/init.d/firewall disable`；暴露面与"lan zone=ACCEPT"相同。
- **活体应用网络结构性变更（新增 alias 接口、改 proto）必须 `/etc/init.d/network restart` 或重启**；
  只 `reload` 不会把新接口拉起来（实测：加 mgmt 别名后 reload，192.168.1.1 不通；重启后才生效）。
  烤进固件首启（=干净启动）则无此问题
- `wifi up` 会清掉临时测试时设的 `disabled` 标志，测完记得检查补回
### 漫游 / 频段引导：谁负责什么（重要，常被混淆）

本固件走**无 steering 守护进程**方案 —— 只靠 hostapd 的 11k/v/r，客户端自主漫游。
（曾装 dawn 做主动引导，多台实测后弃用，原因见下。）

| 机制 | 作用 | 生效条件 |
|---|---|---|
| **802.11r** | AP 间切换快速重认证（FT），**完全由 hostapd 完成，不需守护进程** | full wpad **+ WPA2/WPA3-PSK** |
| **802.11k** | 给客户端邻居列表（无控制器时只含本 AP 自己的 BSS，跨 AP 靠客户端自扫） | full wpad |
| **802.11v** | AP 响应 BSS Transition 查询（无控制器时不主动发起引导） | full wpad |

- **漫游本身照常工作**：客户端自己判断信号、决定何时切；11r 让切换快而无感。丢的只是"主动驱赶粘性客户端"。
- **11r 默认在配置里开着，但开放 SSID 下惰性**；设了 PSK 才激活。全 fleet 的 `mobility_domain`、SSID、加密、密钥必须一致，FT 才能跨 AP。
- ⚠️ **客户端才是最终决定者**：AP 侧只能建议。少数粘性老设备可能赖在远端 AP/2.4G 上；这种场景才需要主动 steering 守护进程。

#### 为什么弃用 dawn（多 AP 实测）

dawn 能做主动 band/AP steering，但在 MR42 + 本设计下不可靠，已移出固件：

- 🔴 **与共享 mgmt 恢复 IP 冲突（根因）**：三台共用 `192.168.1.1` 便于直连救援。dawn 的 umdns 模式(opt2)
  把每台都通告出 `192.168.1.1`，dawn 取首个 IP 连过去 = **连到本机自己**（`netstat` 实证
  `192.168.1.1:xxxxx → 192.168.1.1:1026` 自连），认不出对等 → 各台只看到自己的 BSS。
- 🔴 **广播模式(opt0)会拖垮 dawn**：能全 mesh 发现，但会收到自己发的广播 → 内存双重注册/释放
  （logread 刷 `mem-audit … ubus.c/msghandler.c/datastorage.c`），约 20min 后进程空转 46% CPU、
  `ubus call dawn get_network` 超时卡死。
- **umdns 模式(opt2)稳定但收敛不全**：即便给唯一 hostname，仍是部分/不对称 mesh（实测一台看全、两台各 2/3）。

**若确实需要 dawn**：给每台**唯一 mgmt IP**（如 `192.168.1.<MAC末字节>`，同一 L2 互达）或去掉共享 mgmt IP，
再用 umdns 模式 + 唯一 hostname；代价是失去"永远 ssh 192.168.1.1"的救援便利，且此版本 dawn 发现仍偏 flaky。
本固件权衡后选择 **保共享 .1.1 + 弃 dawn**。

- 🔴 **OpenWrt 默认所有 wifi 接口 `disabled='1'`（wifi 默认关）**；配好 radio 后必须 `uci -q delete wireless.<iface>.disabled` 才会广播。
  ⚠️ 默认启用 = 广播开放 SSID 并桥接 LAN，不安全；生产环境应设 SSID+密码后再启用。
- 802.11k/v/r 都需要 **full 版 `wpad-mbedtls`**（basic 版无 11v/完整 11k）。
  **11r 只有在设了 WPA2/WPA3-PSK（`encryption`+`key`）后才真正生效**；`encryption=none` 时这些项惰性存在、无害。
  全 fleet 的 `mobility_domain`、SSID、加密、密钥必须一致，FT 才能在 AP 间漫游

## 参考

- [OpenWrt: dumb AP / 网桥式 AP](https://openwrt.org/docs/guide-user/network/wifi/dumbap)
- [OpenWrt: 802.11r/k/v 快速漫游](https://openwrt.org/docs/guide-user/network/wifi/80211r)
- [OpenWrt: 别名接口（aliases）](https://openwrt.org/docs/guide-user/network/network_configuration)
- [openwrt/dawn](https://github.com/openwrt/dawn) — 客户端引导守护（本固件未采用，见上"为什么弃用 dawn"）
