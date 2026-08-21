# MR42 定制固件包清单（OpenWrt 25.12.5 / ipq806x）

> 定位：哑 AP + 有线回程 + 多 AP 漫游，不含 mesh。
> 用法：粘进 https://firmware-selector.openwrt.org/ 的 "Customize installed packages"。
> 命令行构建见文末。

## 一行版（直接复制）

```
-kmod-ath10k-ct kmod-ath10k -ath10k-firmware-qca9887-ct ath10k-firmware-qca9887 -ath10k-firmware-qca99x0-ct ath10k-firmware-qca99x0 -wpad-basic-mbedtls wpad-mbedtls -dnsmasq -firewall4 -luci-app-firewall -ppp -ppp-mod-pppoe -luci-proto-ppp odhcpd-ipv6only dawn luci-app-dawn luci-app-statistics collectd-mod-cpu collectd-mod-thermal collectd-mod-interface collectd-mod-wireless nlbwmon luci-app-nlbwmon prometheus-node-exporter-lua luci-app-watchcat iperf3 ethtool htop tcpdump
```

增量约 4 MB（编进 squashfs 压缩后更少）。删掉 Meraki UBI 卷后有 ~51.6 MB 可用。

## 分组说明

| 组 | 包 | 说明 |
|---|---|---|
| 🔴 驱动 | `-kmod-ath10k-ct kmod-ath10k` + 两个 firmware 同样换成非 -ct | **必换**：ath10k-ct 把 5G 锁 40MHz（详见 `ath10k-ct-issue.md`）。必须构建时换，事后 apk 会被 sysupgrade 覆盖回去 |
| 无线 | `-wpad-basic-mbedtls wpad-mbedtls`、`dawn`、`luci-app-dawn` | full 版 wpad 才有 802.11v；没有它 dawn 只能"踢"不能"劝"。dawn=漫游决策 |
| 哑 AP | `-dnsmasq -firewall4 -luci-app-firewall -ppp -ppp-mod-pppoe -luci-proto-ppp`、`odhcpd-ipv6only` | 关掉会和主路由抢的服务；`odhcpd-ipv6only` 只做 IPv6 中继（官方默认已带） |
| 监控 | `luci-app-statistics` + `collectd-mod-{cpu,thermal,interface,wireless}`、`nlbwmon`+`luci-app-nlbwmon`、`prometheus-node-exporter-lua` | `collectd-mod-thermal` 尤重要（吸顶封闭机壳过热降频）；prometheus exporter 供多台接中央 Grafana。**exporter 默认只绑 loopback**，要中央 Prometheus 抓取须 `uci set prometheus-node-exporter-lua.main.listen_interface='lan'`（首启已配） |
| 诊断/稳定 | `iperf3`（测吞吐唯一可靠办法）、`ethtool`、`htop`、`tcpdump`、`luci-app-watchcat`（挂了自动重启） | |

## 不装 mesh

社区第一推荐是**有线回程**；MR42 也没有可用的专用回程射频（第三颗只有 1×1），
无线回程必牺牲一半吞吐。且 `wpad-mesh-mbedtls` 与 `wpad-mbedtls` 互斥——走 mesh 就拿不到 full 的 11k/v。
真要 mesh（拉不了线）：加 `kmod-batman-adv batctl-default mesh11sd`，并把 `wpad-mbedtls` 换成 `wpad-mesh-mbedtls`。

## 首启默认配置

单网口 = 只能当哑 AP。构建时把 `radio-config.md` 里的「哑 AP 首启默认」代码块贴进
firmware-selector 的 **"Script to run on first boot (uci-defaults)"** 框，
刷完开机即 DHCP 客户端 + 固定 mgmt IP（192.168.1.1）+ 关 DHCP 服务，无需手动改。

## 命令行构建（可选，跨平台）

```sh
cat > req.json <<'JSON'
{ "target":"ipq806x/generic", "profile":"meraki_mr42", "version":"25.12.5",
  "packages":[ "把一行版逐项填进来" ] }
JSON
curl -s -X POST https://sysupgrade.openwrt.org/api/v1/build \
     -H 'Content-Type: application/json' -d @req.json | tee resp.json
# 轮询 https://sysupgrade.openwrt.org/api/v1/build/<request_hash> 到 status=200，
# 再从 https://sysupgrade.openwrt.org/store/<hash>/<image> 下载并核对 sha256。
```

> 同样的包列表 → 相同 request_hash → 可复现同一份固件（批量多台方便）。
> 查包名注意文件名含 `~`（如 `...68036~04ab59d.apk`），正则漏掉 `~` 会误判"不存在"。

> **OTA 更新检查**：`owut` + `luci-app-attendedsysupgrade` 提供；`attendedsysupgrade.client.login_check_for_upgrades` 出厂即 `1`（登录 LuCI 自动检查更新），首启脚本已显式固化。
