# Meraki MR42 硬件实测笔记

> 2026-08-20 在一台刷好 OpenWrt 25.12.5 (r33051) 的 MR42 上实测。
> 数据来自 `iw` / `iwinfo` / `dmesg`，非厂商标称值。

## 三颗射频

| LuCI | phy | PCI ID | 频段 | 天线/空间流 | 实测 Tx-Power | 用途 |
|---|---|---|---|---|---|---|
| `radio0` | phy0 | `168c:0040` (QCA9990) | 5 GHz | **3×3**, MCS 0–23 | **23 dBm** | ✅ 主力，性能最好 |
| `radio1` | phy1 | `168c:0040` (QCA9990) | 2.4 GHz | **3×3**, MCS 0–23 | 30 dBm（存疑，见下） | ✅ IoT / 老设备 |
| `radio2` | phy2 | `168c:0050` | 双频(硬件) | **1×1**, MCS 0–7 | 23 dBm | ❌ **扫描射频，别开 SSID** |

UCI `path` 与 phy **一一对应且同序**（实测确认）：

```
radio0 -> soc/1b500000.pcie/.../0000:01:00.0 -> phy0
radio1 -> soc/1b700000.pcie/.../0001:01:00.0 -> phy1
radio2 -> soc/1b900000.pcie/.../0002:01:00.0 -> phy2
```

## 关于 Tx-Power 的结论（2026-08-21 修正）

**txpower = min(监管上限, 硬件能力, 配置值)。实测中监管域才是主要变量。**

### 实测：txpower = min(监管上限, 硬件上限)

**先看监管起作用的三组 —— txpower 精确等于当时的监管上限：**

| 国家码 | 信道 | 段 | 监管上限 | **实测 txpower** |
|---|---|---|---|---|
| US | 36 | UNII-1 | 23 dBm | 23 |
| GB | 132 | UNII-2C | 26 dBm | 26 |
| AU | 144 | UNII-2C | 26 dBm | 26 |

### 硬件天花板 = **30 dBm (1 W)**，已探到

在 AU/ch149 上做了一次**有效**的判决性实验：

```
设备生效的 AU 规则:  (5730 - 5850 @ 80), (N/A, 36)   ← 监管允许 36 dBm
iw dev phy1-ap0 set txpower fixed 3300               ← 请求 33 dBm，命令被接受
iw dev phy1-ap0 info → txpower 30.00 dBm             ← 实际卡在 30
```

**监管给 36、请求 33、实际 30** —— 瓶颈首次不再是监管，而是
**QCA9990 + ART 校准数据的硬件上限 = 30 dBm (1 W)**。

| 国家码/信道 | 监管上限 | 实测 | 瓶颈 |
|---|---|---|---|
| US ch36 | 23 | 23 | 监管 |
| GB ch132 | 26 | 26 | 监管 |
| AU ch144 | 26 | 26 | 监管 |
| **AU ch149** | **36** | **30** | **硬件** |

最初"23 dBm 是 QCA9990 硬件上限"的判断完全错误 —— 那只是 US/UNII-1 的法规值。

### ⚠️ 但不要盲目拉满：上下行不对称

AP 发 30 dBm，而手机/笔记本通常只有 **15–20 dBm**。单方面拉高 AP 功率会导致：

- 客户端**能收到**很远处的 AP，于是**赖着不漫游**
- 但它自己**回不来** —— 上行断在半路
- 表现：**满格信号却网速极慢、频繁超时**（典型的"假覆盖"）

**有效覆盖由较弱的一端（客户端）决定。** 多 AP 部署通常应把功率**降到 20–23 dBm**，
让覆盖边界清晰、漫游果断 —— 高功率会加剧客户端粘滞，正是 dawn 要对抗的问题。
30 dBm 更适合"单台打穿全屋"的场景。

2.4 GHz 同理：GB(ETSI) 下 20 dBm、AU 下 30 dBm，也是跟着监管走。

### 监管域对照（AU vs GB vs US）

注意 AU/GB 的 regdb 用 **mW（EIRP）**，US 用 **dBm**：

| 段 | AU | GB | US |
|---|---|---|---|
| 2.4 GHz | **4000 mW → 实得 30 dBm** | 100 mW (20 dBm) | 30 dBm |
| 5150–5250 | 200 mW | 200 mW | 23 dBm |
| 5250–5350 | 100 mW | 100 mW | 24 dBm |
| 5470–5730 | 500 mW (26 dBm), DFS | 500 mW (26), DFS | 24 dBm, DFS |
| **5730–5850 (UNII-3)** | **4000 mW → 实得 30 dBm，无 DFS** | 200 mW (23) | 30 dBm |

**UNII-3(ch149–165)是最优段**：功率最高且**免 DFS** —— 不用等 60 秒 CAC，
也不会因雷达误检强制切换中断。实测锁 ch149 后接口 0 秒起来（对比 ch144 要 CAC 60s）。

### ❌ World domain（`00`）是最保守的，不是"不受限"

常见误解。`country 00` 取所有国家的**交集**：

```
(2402 - 2472 @ 40), (20)
(2457 - 2482 @ 20), (20), NO-IR      ← ch12-13 不能主动发射
(5170 - 5250 @ 80), (20), NO-IR      ← 5G 低段也 NO-IR
```

`NO-IR` = No Initiate Radiation，**AP 模式下根本不能在这些信道建网**。
5G 几乎全被 NO-IR 封死，功率统一压到 20 dBm。**没有"debug 国家码"这种东西**；
真要绕过只能编译时开 `CONFIG_CFG80211_CERTIFICATION_ONUS` 或改 `regulatory.db`（有签名校验）。

### ⚠️ 早先的错误结论（已推翻，留作教训）

初测时在 `US` 下看到 5G 恒为 23 dBm，曾据此断言"23 dBm 是硬件上限"。
所谓"决定性实验"是在 AP 模式下执行 `iw dev phy0-ap0 set channel 149` 后回读 txpower 未变
—— **该实验无效**：hostapd 运行时掌管信道与功率，`iw set channel` 不会真正切换工作信道
（回读输出里仍是 `channel 36` 即为铁证），功率当然不变。

**正确做法**：改 UCI 配置后 `wifi up`，让 hostapd 重新协商。

### 各监管域下的信道功率表

| 段 | 信道 | GB/ETSI | US/FCC |
|---|---|---|---|
| UNII-1 | 36–48 | 23 dBm | 23 dBm |
| UNII-2A | 52–64 | 20 dBm | 24 dBm |
| **UNII-2C** | **100–144** | **26 dBm** ⭐ | 24 dBm |
| UNII-3 | 149–165 | 23 dBm | 30 dBm（法规值，硬件未必达到）|
| 2.4 GHz | 1–13 | **20 dBm**（ETSI 100mW）| 30 dBm（法规值直报）|

实测 ACS 选中 ch132（UNII-2C）时，`txpower 26.00 dBm` —— 说明
**5G 硬件能力 ≥ 26 dBm，真实上限未测到**。

US 下 2.4G 报的 30 dBm 与 UNII-3 报的 30 dBm 都只是"驱动把监管值直接报上来"，
吸顶 AP 不可能真发 1 W。GB 下 2.4G 的 20 dBm 才是可信的合规值。

### 仍然成立的结论

**phy2（1×1 扫描射频）的 23 dBm 具有误导性。** 每链功率相同，但它只有 1 根天线；
3×3 主射频三链齐发总辐射约为其 3 倍（+4.8 dB）。
LuCI 里 radio2 会显示成 5GHz/VHT80，**看起来像第二个 5G 主射频，极具迷惑性** ——
默认配置生成器只看频段能力、看不出天线数。

## 部署建议

- **5G**：功率随信道段变化。在 GB，**UNII-2C（ch100–144）可达 26 dBm**，比 UNII-3 高 3 dB；
  代价是 DFS（遇雷达须让路并中断约 60s）。求稳选 UNII-3（免 DFS，23 dBm）
- **2.4G**：GB 下本就被 ETSI 限在 20 dBm，与 5G 的 23–26 dBm 差距合适，**无需再手工调低**
- **radio2**：不配 SSID。空着还有个好处：漫游时不会有一个"弱 AP 信号"把客户端骗过去粘住
- 覆盖 vs 稳定的取舍：**UNII-2C 功率高 3 dB 但有 DFS**；**UNII-3 免 DFS 但低 3 dB**。
  附近有气象雷达/机场就锁 UNII-3

## 固件

```
ath10k 6.15 driver, optimized for CT firmware
firmware ver 10.4b-ct-9980-fW-14-fcb240f04 api 5
board_file api 2 bmi_id 1:1
max-sta 32
```

用的是 **Candela Tech (CT) 固件**，非 QCA 原版；稳定性与统计信息通常更好。

## 🔴 最重要的坑：radioN 编号与频段**不固定对应**

**刷新固件重新生成 `/etc/config/wireless` 时，PCIe 枚举顺序会变，
radio0/radio1 与 2.4G/5G 的对应关系可能整个对调。**

2026-08-21 实测（同一台机器，刷定制固件前后）：

| | 刷之前 | 刷之后 |
|---|---|---|
| `radio0` | path `1b500000` = **5GHz** | path `1b700000` = **2.4GHz** |
| `radio1` | path `1b700000` = 2.4GHz | path `1b500000` = **5GHz** |

按旧假设写 `radio0=5g/VHT80` 的后果：netifd 检测到频段不符会**自动纠正 `band`，
但不纠正 `htmode`** → **5GHz 被设成 HT20，白白浪费 80MHz 能力**，
而且表面看不出错（接口正常起来、能连、能上网）。

### 正确做法：按 **PCIe path** 判断，绝不按编号

MR42 的 path 由硬件决定，永不改变：

| path | 射频 | 说明 |
|---|---|---|
| `soc/1b500000.pcie/...` | QCA9990 **5GHz 3×3** | 主力 |
| `soc/1b700000.pcie/...` | QCA9990 **2.4GHz 3×3** | |
| `soc/1b900000.pcie/...` | `168c:0050` 双频 **1×1** | 扫描射频，不开 SSID |

现成脚本见同目录 **`uci-defaults-mr42-ap.sh`**（按 path 判断，可直接贴进
firmware-selector 的 first-boot script）。退化情形按 `band` 判断，同样不用编号。

## ⚠️ 无线配置的三个非直觉行为

**1. 国家码只在 hostapd 真正启动后才写进 regdomain。**
接口全 `disabled` 时 `iw reg get` 会一直显示默认的 `US`，看着像没生效 —— 其实
配置已经写好了，等接口起来自然变。别据此反复改配置。

**2. `wifi reload` 不会拉起已经 down 的接口。**
执行过 `wifi down` 后，`ubus call network.wireless status` 里会看到
`"autostart": false`；此时 `wifi reload` 只重载配置、不启动，必须用 **`wifi up`**。

**3. `wifi up` 会清掉 `wifi-iface` 的 `disabled` 标志。**
临时启用某个 radio 做测量后，即使 `uci revert`，磁盘配置里该 iface 的
`disabled='1'` 也已被 netifd 写掉 —— **重启后会自动广播 SSID**。测完务必检查补回：

```sh
uci show wireless | grep disabled       # 每个该关的 iface 都要有
uci set wireless.default_radioN.disabled='1'; uci commit wireless
```

## 实测可用的一套配置（25.12.5，已验证）

```
国家码      GB（DFS-ETSI）
2.4GHz      auto 信道 / HT20  / 20 dBm
5GHz        auto 信道 / VHT80 / 23–26 dBm（取决于 ACS 选中的段）
扫描射频    禁用
802.11k/v   ieee80211k + rrm_neighbor_report + rrm_beacon_report
            + bss_transition + wnm_sleep_mode
dawn        随固件预装并自启
```

⚠️ **802.11v(`bss_transition`/`wnm_sleep_mode`) 需要 full 版 `wpad-mbedtls`**。
官方默认的 `wpad-basic-mbedtls` 没有 WNM（二进制里 `wnm_` 字符串为 0），
缺了它 dawn 只能"踢"不能"劝"，漫游体验差很多。

## ⚠️ 实测踩到的坑

**`wifi up` 会清掉 `wifi-iface` 的 `disabled` 标志。**
临时启用 radio 做测量后，即使 `uci revert`，磁盘配置里该 radio 的 `disabled='1'`
也已被 netifd 写掉 —— **重启后会自动广播无加密 SSID**。测完务必检查并补回：

```sh
uci show wireless | grep disabled       # 三个都该有
uci set wireless.default_radioN.disabled='1'; uci commit wireless
```

## 其他实测事实

- **国家码默认是 `US`**（未设置时的 fallback）。US 下 2.4G 只有 ch1–11。
  按实际所在地设置是法律要求：`Network → Wireless → radio0 → Advanced → Country Code`
- **25.12.5 的包管理器是 `apk`，不是 `opkg`**
- 出厂默认 **DHCP 服务器是开着的**（dnsmasq 监听 `0.0.0.0:67`，池 `.100` 起 150 个）。
  当 AP 用必须关掉，否则和主路由抢着发 IP
- **reset 按钮有两套行为**：
  - **上电时按住** → cryptid u-boot 拦截 → **TFTP 网络引导**（不是重置！）
  - **运行中**短按 → 重启；**按住 ≥5 秒** → 恢复出厂（`factoryreset -y`）
- 多 AP 漫游选包：`dawn`（LuCI 能看全网客户端分布，多台推荐）或 `usteer`（nbd 出品，更轻量）。
  两者都在官方源，**默认固件都不预装**；需配合 hostapd 的 802.11k/v/r

## 🔴 ath10k-ct 驱动会把 5G 发射限制在 40MHz（✅ 本机已验证并修复）

> **实测结果：换标准 ath10k 后，iPhone 下行 TCP 从 ~300 Mbps → ~500 Mbps（+67%）。**
> 同时 `tx failed` 从 111959 归零（CT 驱动的失败计数本身就是它限制带宽的副产物）。

**症状**：客户端上行满速 80MHz，AP 下行恒定 40MHz，且调制已是最高的 MCS9。

```
tx bitrate: 400.0 MBit/s VHT-MCS 9 40MHz  ← AP→client（下行），恒定不变
rx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz  ← client→AP（上行），随链路自适应
```

实测下行 TCP 只有 ~300 Mbps（400 PHY × 75% 效率，符合预期），上行可到 700+。

### 排查中被逐项排除的因素

| 嫌疑 | 排除依据 |
|---|---|
| 信道干扰 | survey 显示 80MHz 四个子信道 busy time 0–2%，scan 到**零个邻居 AP** |
| 信号弱 | `-24 dBm`，极强 |
| AP CPU 瓶颈 | `top` 显示 **100% idle**；把 iperf3 -s 换到 Mac 上跑结果相同 |
| 有线段瓶颈 | `ethtool eth0` = 1000Mb/s Full |
| **功率过高致失真** | **已推翻** —— 降到 20 dBm 后 tx 仍是 40MHz |
| rate control 降级 | **不成立** —— 用的是最高 MCS9，只有带宽是 40MHz |
| 客户端省电(OMN) | 插着充电线，且上行始终 80MHz |

关键观察：**MCS9 + 40MHz** 说明 rate control 对调制毫无保留，
它只是**认定发射带宽为 40MHz** —— 这是驱动层面的限制，不是链路自适应的结果。

### 根因与解法

[OpenWrt issue #8262 (FS#3405)](https://github.com/openwrt/openwrt/issues/8262)
在 TP-Link EAP245v3 (QCA9982) 上报告了完全相同的症状，
并**用频谱分析仪实测确认 ath10k-ct 真的把发射限制在 40MHz**（不是报告错误，是真实吞吐限制）。

**解法：换用标准 `ath10k` 驱动（非 CT 版）。**

固件包列表改动：

```
-kmod-ath10k-ct              kmod-ath10k
-ath10k-firmware-qca9887-ct  ath10k-firmware-qca9887
-ath10k-firmware-qca99x0-ct  ath10k-firmware-qca99x0
```

⚠️ **必须在固件构建时替换**，不能事后 `apk` 换：
MR42 的 `device_packages` 里写死了 `ath10k-firmware-*-ct`，apk 层面的替换会在下次 sysupgrade 时被覆盖回去。

⚠️ 换标准 ath10k 后，`iw` 报告的 tx bitrate 可能显示成 **6.0 Mbit/s** ——
这是标准 ath10k 的已知报告缺陷，issue 里频谱仪确认实际仍是 80MHz。
**判断标准以 iperf3 实测吞吐为准，别看 iw 的报告数字。**

本机实测：换标准 ath10k 后 `tx bitrate` 干脆**不再报告**（比 issue 里的 6 Mbit/s 更彻底），
但 iperf3 实测 500 Mbps —— 证明它确实在用 80MHz 发射。

### 修复前后对比（同一台 iPhone，2×2 VHT80）

| | ath10k-ct | 标准 ath10k |
|---|---|---|
| 下行 TCP | ~300 Mbps | **~500 Mbps** |
| 上行 TCP | ~700 Mbps | ~700 Mbps |
| tx bitrate 报告 | 400.0 MBit/s **40MHz** MCS9 | 不报告（驱动缺陷）|
| rx bitrate | 866.7 MBit/s 80MHz MCS9 | 866.7 MBit/s 80MHz MCS9 |
| **tx failed** | **111959** | **0** |

500 Mbps / 866.7 PHY = **58% 效率**，属无线 TCP 的正常区间（50–65%）。
iPhone 是 2×2，吃不满 MR42 的 3×3；3×3 客户端可望更高。

## 换标准 ath10k 的代价：只丢一个统计字段

ath10k 的很多统计**不是驱动算的，是固件上报的**。CT 固件的 features 里有
`txrate-CT` / `txrate2-CT` / `cust-stats-CT` / `tx-rc-CT` —— 这些是 Candela Tech
的**统计增强扩展**（CT 固件本来就是给 WiFi 测试仪表用的，统计详尽是其卖点）。
标准固件没有这些扩展，驱动拿不到数据。

**实测影响范围（本机验证）：**

| 数据 | 标准 ath10k |
|---|---|
| `tx bitrate` | ❌ **丢失**（唯一损失） |
| `signal` / `signal avg`（含每天线明细） | ✅ |
| `rx bitrate` | ✅ |
| `tx failed` / `tx retries` / `tx duration` | ✅ |
| tx/rx bytes、packets | ✅ |
| **dawn 的全部输入** | ✅ |
| 802.11k beacon report | ✅ |

**dawn 不受影响** —— 它的决策基于 `signal` / `rcpi` / `rsni` /
`channel_utilization` / `num_sta` / `neighbor_report`，**没有一项依赖 tx bitrate**：

```json
"signal": -35, "rcpi": 186, "rsni": 255,
"channel_utilization": 0, "num_sta": 1,
"neighbor_report": "0c8ddb71eda0ef1900008095090603029b00"
```

**对监控的影响**：`collectd-mod-wireless` 的信号类曲线完好，
`luci-app-statistics` 里**发送速率那条线会是空的**。

**结论**：用一个显示字段换 67% 的真实吞吐，划算。
且该字段在 CT 下显示的本就是"被人为限制到 40MHz 的速率"，参考价值有限。

## ⚠️ `irqbalance` 在 IPQ806x 上无效

三个 ath10k 中断全压在 CPU0、CPU1 恒为 0，但**无法调整**：

```
49: PCI-MSI Edge ath10k_pci
echo 1 > /proc/irq/49/smp_affinity  → 写入失败，读回仍是 mask=3
irqbalance                          → 启动后自行退出（发现无法调整）
```

这些 PCI-MSI 中断在该平台不支持 affinity 设置。**`irqbalance` 是无效包，可从包列表移除。**
（好在这不是瓶颈：300 Mbps 时 CPU 仍 100% idle。）

## 💡 squashfs 机型上 `apk del` 的真相：whiteout

**`apk del` 不会真的删除固件里的文件**，只是在 overlay 上盖了块遮羞布。

```
/          = overlayfs
├── lowerdir → /rom      (squashfs，只读，固件原始内容)
└── upperdir → /overlay  (UBIFS，可写)
```

删除只存在于 squashfs 的文件时，overlayfs 在 upperdir 创建一个
**whiteout**（`(0,0)` 字符设备）标记"此路径已删除"。原文件在 `/rom` 下完好无损。

实测（误删整个无线栈后）：

```
/rom/lib/modules/6.12.94/ath10k_core.ko   547176 bytes  ← 还在
/rom/lib/firmware/ath10k/{QCA9887,QCA99X0}              ← 还在
/overlay/upper 下 100 个 whiteout 遮着它们
当前可见 ath10k 模块: 0
```

**推论**：
- squashfs 机型上 `apk del` **不省空间，反而费空间**（每个 whiteout 占 overlay 一条记录）
- **误删系统包不必重刷**，删掉 whiteout 即可原地复活：
  ```sh
  find /overlay/upper -type c -exec rm -f {} \;
  ```
  （只在确认这些 whiteout 都是误删产生时才这么做）
- `firstboot` 能"还原一切"，正是因为它直接清空 overlay，whiteout 一并消失

⚠️ 另一个坑：`apk del <pkg>` 会**级联删除依赖**。误删 `kmod-ath10k-ct` 时
连带删掉了 27 个包（整个 mac80211/crypto 依赖栈）。设备若未联网就无法 `apk add` 补回。
