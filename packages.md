# MR42 定制固件包清单（OpenWrt 25.12.5 / ipq806x / arm_cortex-a15_neon-vfpv4）

> 定位：**哑 AP（dumb AP）+ 有线回程 + 多 AP 漫游**。不含 mesh。
> 全部包名已于 2026-08-20 在官方仓库核实存在（base / luci / packages / routing / kmods 五个 feed）。
> 用法：粘进 https://firmware-selector.openwrt.org/ 的
> "Customize installed packages and/or first boot script"。

## 一行版（直接复制）

```
-wpad-basic-mbedtls -dnsmasq -odhcpd -firewall4 -luci-app-firewall -ppp -ppp-mod-pppoe wpad-mbedtls odhcpd-ipv6only dawn luci-app-dawn luci-app-statistics collectd-mod-cpu collectd-mod-thermal collectd-mod-interface collectd-mod-wireless luci-app-nlbwmon nlbwmon irqbalance luci-app-watchcat iperf3 ethtool htop tcpdump
```

增量约 **4 MB**（编进 squashfs 压缩后更少）。MR42 删掉 Meraki UBI 卷后有 ~51.6 MB 可用。

## 分组说明

### ① 移除（哑 AP 用不到）
```
-wpad-basic-mbedtls -dnsmasq -odhcpd -firewall4 -luci-app-firewall -ppp -ppp-mod-pppoe
```
`wpad-basic-mbedtls` **必须移除**，否则与 full 版冲突（同名 provider）。

### ② 无线核心（必装，~1 MB）
```
wpad-mbedtls dawn luci-app-dawn
```
- `wpad-mbedtls` — **full 版**。官方默认的 `wpad-basic-mbedtls` 只有 WPA-PSK/SAE/**11r**/11w，
  **缺 802.11v**（二进制里 `wnm_` 字符串为 0）。没有 11v，dawn 只能"踢"不能"劝"，漫游体验差。
  大小对比（实测）：basic 514 KB → full 869 KB，仅 +355 KB。
- `dawn` / `luci-app-dawn` — 多 AP 漫游决策；LuCI 可看全网客户端分布在哪台 AP。

### ③ 哑 AP 专属（必装，~50 KB）
```
odhcpd-ipv6only
```
哑 AP 不该跑完整 `odhcpd`（会与主路由抢 DHCPv6），但仍需从主路由取得 IPv6。
这个精简版只做 IPv6，不发 IPv4 —— 社区哑 AP 标准做法。

### ④ 监控（多台强烈推荐，~1.5 MB）
```
luci-app-statistics collectd-mod-cpu collectd-mod-thermal collectd-mod-interface collectd-mod-wireless
luci-app-nlbwmon nlbwmon
```
- `collectd-mod-thermal` — **IPQ8064 在吸顶封闭机壳内，过热降频是首要排查项**
- `collectd-mod-wireless` — 信号强度 / 噪声曲线
- `nlbwmon` — 每客户端流量统计

多台推荐另加（接中央 Prometheus + Grafana，比逐台点 LuCI 高效）：
```
prometheus-node-exporter-lua
```
`luci-app-statistics` 的 RRD 出图是每台各存各的；要跨 AP 对比（同一客户端在哪台信号更好、
哪台先过热降频），中央时序库更合适。

### ⑤ 诊断（推荐，~1.5 MB）
```
iperf3 ethtool tcpdump htop
```
`iperf3` 是**测无线实际吞吐的唯一可靠办法**，安装选点时用来验证覆盖。

### ⑥ 稳定性（可选，~200 KB）
```
irqbalance luci-app-watchcat
```
- `irqbalance` — IPQ8064 **双核**，三颗射频中断默认可能全压在 CPU0
- `luci-app-watchcat` — 网络异常自动重启；吸顶部署够不着时实用

> `bridger` 不建议：其流量卸载主要针对 MediaTek WED，ipq806x 上效果存疑。

## 不装 mesh 的理由

社区第一推荐是**有线回程**：
> "If every access point has Ethernet, you do not have a mesh routing problem —
> you have several wired access points serving the same networks."

MR42 另有硬件层面的理由：**没有可用的专用回程射频**。
三颗射频中 radio2 只有 **1×1**（扫描射频），radio0/radio1 才是 3×3。
任何无线回程都要牺牲一半吞吐，而有线回程没有这个损失。

另外 `wpad-mesh-mbedtls`（764 KB）与 `wpad-mbedtls`（869 KB）**互斥**：
mesh 版是 basic 血统，**不含 full 的 11k/v**。不走 mesh 才能拿到完整 11k/v/r。

若将来确实拉不了线，mesh 组为（routing feed + kmods feed）：
```
kmod-batman-adv batctl-default mesh11sd
```
同时须把 `wpad-mbedtls` 换成 `wpad-mesh-mbedtls`。

## Feed 位置备忘

排查"包找不到"时有用（设备上六个 feed 默认已全部配置）：

| feed | 内容 |
|---|---|
| `base` | `wpad-*`、`odhcpd-ipv6only`、`ethtool` |
| `luci` | 全部 `luci-app-*`、`luci-mod-*` |
| `packages` | `dawn`、`usteer`、`nlbwmon`、`collectd-*`、`iperf3`、`htop`、`tcpdump`、`irqbalance` |
| `routing` | **`batctl-*`、`mesh11sd`、`babeld`、`olsrd`**（易漏查的 feed） |
| kmods（target 下独立目录） | `kmod-batman-adv`、`kmod-ath10k*` 等全部内核模块 |

> ⚠️ 查包名时注意文件名含 `~`（如 `luci-app-dawn-26.230.68036~04ab59d.apk`），
> 正则字符集漏掉 `~` 会把包名截断成碎片、误判为"不存在"。
