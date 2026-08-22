# MR42 硬件实测笔记

> 2026-08 在一台刷了 OpenWrt 25.12.5 的 MR42 上实测。只记结论。
> ath10k-ct 40MHz 问题的完整排查见 `ath10k-ct-issue.md`。

## 三颗射频

| LuCI | phy | 芯片 | 频段 | 天线/流 | 用途 |
|---|---|---|---|---|---|
| radio0/1（编号不固定，见下） | — | QCA9990 `168c:0040` | 5GHz | **3×3** | ✅ 主力 |
| | — | QCA9990 `168c:0040` | 2.4GHz | **3×3** | ✅ IoT/老设备 |
| | — | `168c:0050` | 双频 | **1×1** | ❌ 扫描射频，不开 SSID |

⚠️ **radioN 编号与频段不固定对应**：刷新固件会重新枚举 PCIe，`radio0`/`radio1` 与
2.4G/5G 可能对调。**配置按 `band` 或 PCIe `path` 判断，绝不按编号写死**（`radio-config.md`）。
MR42 的 path 恒定：`1b500000`=5G 3×3、`1b700000`=2.4G 3×3、`1b900000`=1×1 扫描。

`radio2`（扫描射频）在 LuCI 里会显示成 5GHz/VHT80，看着像第二个 5G 主射频，
但只有 1 根天线，总辐射约为 3×3 主射频的 1/3。别用它开 SSID。

## Tx-Power

**实际功率 = min(监管上限, 硬件上限)。硬件天花板 = 30 dBm (1W)。**

各监管域下 5G 各段的功率上限（实测每次 txpower 都精确等于当时的监管值）：

| 段 | 信道 | AU | GB | US |
|---|---|---|---|---|
| UNII-1 | 36–48 | 23 | 23 | 23 |
| UNII-2A | 52–64 | 20 | 20 | 24 |
| UNII-2C | 100–144 | 26 | 26 | 24（DFS） |
| **UNII-3** | **149–165** | **30** | 23 | 30 |
| 2.4GHz | 1–13 | 30 | 20 | 30 |

- **UNII-3 (ch149) 最优**：AU 下满 30 dBm 且**免 DFS**（不用等 60s CAC、不会因雷达中断）
- 硬件上限确认过：AU/ch149 监管允许 36、`iw set txpower 33` 也只给 30 → 30 是硬件顶
- **注意 30 dBm 不是单链**：它是固件 `tpc_stats` 里的 Power Limit（聚合/EIRP 口径）。
  实测单链目标 ~21 dBm（VHT80），3 链合并总传导 ~25.5 dBm，加内置天线 ~4 dBi → **实际 EIRP ~29–30 dBm**。
  监管限的是 EIRP，所以不能"单链×3"——固件先定 EIRP 目标再压低每链，加链数不加总功率
- **World domain `00` 是最保守的，不是"不受限"**：多段 `NO-IR`（AP 不能建网），功率压到 20 dBm
- 没有"debug 国家码"；国家码按实际所在地设（法律要求）

**别盲目拉满**：AP 发 30 而手机只发 15–20，功率过高会让客户端"满格却连不上"、
赖在远处 AP 不漫游。多 AP 部署通常降到 20–23 dBm，覆盖边界更清晰。

## ath10k-ct 会把 5G 发射锁在 40MHz（务必换标准驱动）

`ath10k-ct` 让 5G 下行恒定 40MHz（下行~300Mbps）；换标准 `ath10k` 后恢复 80MHz（~500Mbps，+67%）。
**必须在构建固件时替换**（`packages.md` 已含）。代价仅一个：标准驱动不报告 `tx bitrate`
（CT 靠私有扩展多报的），`signal`/`rx bitrate`/重传计数/11k/v 漫游输入 全部完好。
完整排查与验证见 `ath10k-ct-issue.md`。

## irqbalance 在 IPQ806x 上无效

ath10k 中断是 **PCI-MSI**，该平台不支持改 affinity（写 `smp_affinity` 被忽略，恒 mask=3）。
三个中断全在 CPU0、CPU1 恒 0，irqbalance 启动即退出。**不装它**（`packages.md` 已移除）。
不影响性能：实测 300Mbps 时 CPU 仍 100% idle。

## squashfs 机型上 `apk del` 只是加 whiteout

`apk del` **不真删** squashfs 里的文件，只在 overlay 加一个 whiteout（`(0,0)` 字符设备）遮住它，
原文件仍在 `/rom`。所以在这类机型上 `apk del` **费空间不省空间**；误删系统包不必重刷：

```sh
find /overlay/upper -type c -exec rm -f {} \;   # 删 whiteout 即原地复活
```

`apk del <pkg>` 还会级联删依赖（误删 kmod-ath10k-ct 曾连带删 27 个包）——设备离线则补不回。

## 固件（原厂 ath10k）

CT 版：`10.4b-ct-9980-fW-14`；标准版：`10.2.4-1.0-00047` / `10.4.1.00030-1`。
`max-sta 32`。原厂内核 3.4，OpenWrt 25.12.5 用 6.12。

## 其他

- 国家码只在 hostapd 启动后才写进 regdomain；接口全 disabled 时 `iw reg get` 显示默认 `US`，不是没生效
- `wifi reload` 不启动已 `wifi down` 的接口，要用 `wifi up`；`wifi up` 会清掉临时设的 `disabled` 标志，测完检查补回
- 25.12.5 包管理器是 **apk**，不是 opkg
- 出厂默认开着 DHCP 服务器，当 AP 用必须关（`radio-config.md`）
- reset 按钮：**上电时按住** = u-boot TFTP 网络引导（不是重置！）；**运行中**短按=重启、按住≥5s=恢复出厂
- 设备**无 RTC 电池**，断电丢时间，靠 NTP（`sysfixtime` 用文件 mtime 兜底，故不会是 1970）。
  联网后 ntpd 自动同步；**busybox ntpd 对小幅校准静默、不写日志**，`logread` 空 ≠ 没同步。
  查状态：`ntpd -n -q -d -p 0.openwrt.pool.ntp.org`，offset 接近 0 即已同步。
  没网关/DNS 时才真的同步不了（如直连一台非 DHCP 主机）
- LED：`orange`/`white` 走 GPIO，`red`/`green`/`blue` 走 I2C 的 TLC59108（RGB 混色）；另有 INA219(功耗)、24c64(板级数据) 两颗 I2C 芯片

## 参考

- [ath10k-ct 5GHz 40MHz 限制 — openwrt/openwrt#8262](https://github.com/openwrt/openwrt/issues/8262)
- [greearb/ath10k-ct](https://github.com/greearb/ath10k-ct) — CT 驱动/固件上游
- [wireless-regdb](https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/tree/db.txt) — 各国监管功率/信道
- [OpenWrt overlayfs / 只读 rootfs](https://openwrt.org/docs/techref/filesystems)
