# ⚠️ ath10k-ct 会把 MR42 的 5GHz 发射锁死在 40MHz

**一句话**：OpenWrt 官方镜像默认的 `ath10k-ct` 驱动让 MR42 的 5G **下行吞吐腰斩**。
换成标准 `ath10k` 后，实测下行从 **~300 Mbps 提升到 ~500 Mbps（+67%）**。

> 本文档记录 2026-08-21 在一台 Meraki MR42（OpenWrt 25.12.5）上的完整排查与修复。
> 修复已写进 `packages.md` 的包列表，按它构建的固件不受此问题影响。

---

## 症状

上行满速、下行腰斩，且**调制已经是最高档**：

```
tx bitrate: 400.0 MBit/s VHT-MCS 9 40MHz short GI VHT-NSS 2   ← AP→客户端，恒定 40MHz
rx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2   ← 客户端→AP，随链路自适应
```

iperf3 实测：**下行 ~300 Mbps / 上行 ~700 Mbps**。

### 最容易误判的地方

看到 40MHz，直觉会以为是「信号差 / 有干扰 / 客户端不行」导致速率自适应降级。
**但 MCS9 是最高调制** —— rate control 对调制毫无保留，说明链路质量完全没问题，
它只是**认定发射带宽就是 40MHz**。这是驱动层面的硬限制，不是自适应的结果。

**记住这个判据：`MCS9 + 40MHz` 的组合 = 驱动限制，不是链路问题。**

---

## 排查过程：被逐项排除的因素

| 嫌疑 | 排除依据 |
|---|---|
| 信道干扰 | `survey dump` 显示 80MHz 的四个子信道 busy time **0–2%**；`scan dump` **零个邻居 AP** |
| 信号弱 | `-24 dBm`，极强 |
| AP CPU 瓶颈 | `top` 显示 **100% idle**；把 `iperf3 -s` 从 AP 换到 Mac 上跑，结果相同 |
| 有线段瓶颈 | `ethtool eth0` = 1000Mb/s Full |
| 发射功率过高致失真 | **降到 20 dBm 后 tx 仍是 40MHz**，假设推翻 |
| rate control 降级 | 用的是最高 MCS9，不成立 |
| 客户端省电 (802.11ac OMN) | iPhone 插着充电线，且上行始终满速 80MHz |
| 中断集中在 CPU0 | 是事实，但 300 Mbps 时 CPU 仍 100% idle，非瓶颈 |

全部排除后，剩下的只能是驱动。

---

## 根因

[OpenWrt issue #8262 (FS#3405)](https://github.com/openwrt/openwrt/issues/8262)
在 TP-Link EAP245v3 (QCA9982) 上报告了**完全相同**的症状：

```
ath10k-ct:  TX 405.0 MBit/s VHT-MCS 6 40MHz  /  RX 1300 MBit/s VHT-MCS 9 80MHz
```

报告者**用频谱分析仪实测**，确认 ath10k-ct **真的把发射限制在 40MHz** ——
这是**真实的吞吐限制，不是报告错误**。换标准 `ath10k` 后，频谱仪确认恢复 80MHz 发射。

### 为什么 OpenWrt 默认用 CT 版

CT = [Candela Tech](https://github.com/greearb/ath10k-ct)，其固件本是给 **WiFi 测试仪表**用的，
卖点是统计详尽（`txrate-CT`、`cust-stats-CT` 等私有扩展）和高客户端密度（`max-sta 32`）。
40MHz 限制大概是这个特化路线的副作用。对家用 / 小型部署，标准固件更合适。

---

## 修复

固件包列表中做三组替换：

```
-kmod-ath10k-ct               kmod-ath10k
-ath10k-firmware-qca9887-ct   ath10k-firmware-qca9887
-ath10k-firmware-qca99x0-ct   ath10k-firmware-qca99x0
```

### 🔴 必须在**构建固件时**替换，不能事后 apk 换

MR42 的 `device_packages` 里**写死了** `ath10k-firmware-qca9887-ct` 和
`ath10k-firmware-qca99x0-ct`，apk 层面的替换**会在下次 sysupgrade 时被覆盖回去**。

而且直接 `apk del kmod-ath10k-ct` 有个大坑 ——
它会**级联删除 27 个包**（整个 mac80211 / crypto 依赖栈）。设备若未联网，
`apk add` 补不回来，无线栈直接消失。

> 万一真的误删了：squashfs 机型上 `apk del` 只是盖了 overlay whiteout，
> 原文件还在 `/rom` 下。删掉 whiteout 即可原地复活：
> `find /overlay/upper -type c -exec rm -f {} \;`
> 详见 `hardware-notes.md` 的 whiteout 章节。

### 在网页上构建（推荐）

https://firmware-selector.openwrt.org/ → 搜 MR42 → 25.12.5 →
"Customize installed packages" → 粘贴 `packages.md` 里的一行版包列表。

---

## 验证结果（同一台 iPhone，2×2 VHT80）

| | ath10k-ct | 标准 ath10k |
|---|---|---|
| **下行 TCP** | ~300 Mbps | **~500 Mbps** |
| 上行 TCP | ~700 Mbps | ~700 Mbps |
| `tx bitrate` 报告 | 400.0 MBit/s **40MHz** MCS9 | **不报告**（见下） |
| `rx bitrate` | 866.7 MBit/s 80MHz MCS9 | 866.7 MBit/s 80MHz MCS9 |
| **`tx failed`** | **111959** | **0** |

`tx failed` 归零是个强信号 —— CT 驱动的失败计数本身就是它限制带宽的副产物。

500 Mbps / 866.7 PHY = **58% 效率**，属无线 TCP 正常区间（50–65%）。
iPhone 是 2×2，吃不满 MR42 的 3×3；3×3 客户端可望更高。

---

## 唯一的代价：丢一个统计字段

ath10k 的很多统计**不是驱动算的，是固件上报的**。CT 固件靠 `txrate-CT` / `txrate2-CT` /
`cust-stats-CT` 等私有扩展多报了发送速率，标准固件没有这些扩展。

**实测影响范围：**

| 数据 | 标准 ath10k |
|---|---|
| `tx bitrate` | ❌ **丢失**（唯一损失） |
| `signal` / `signal avg`（含每天线明细） | ✅ |
| `rx bitrate` | ✅ |
| `tx failed` / `tx retries` / `tx duration` | ✅ |
| tx/rx bytes、packets | ✅ |
| **11k/v 漫游所需数据**（signal/rcpi/rsni 等） | ✅ |
| 802.11k beacon report | ✅ |

**11k/v 漫游数据完好** —— 客户端引导/邻居报告用到的 `signal` / `rcpi` / `rsni` /
`channel_utilization` / `num_sta` / `neighbor_report` 都在，没有一项依赖 `tx bitrate`：

```json
"signal": -35, "rcpi": 186, "rsni": 255,
"channel_utilization": 0, "num_sta": 1,
"neighbor_report": "0c8ddb71eda0ef1900008095090603029b00"
```

**对监控**：`collectd-mod-wireless` 的信号类曲线完好，
`luci-app-statistics` 里发送速率那条线会是空的。

**这笔买卖划算** —— 用一个显示字段换 67% 的真实吞吐。
何况该字段在 CT 下显示的本就是"被人为限制到 40MHz 的速率"，参考价值有限。

---

## ⚠️ 换驱动后别看 `iw` 的 tx bitrate 判断成败

标准 ath10k 有已知的报告缺陷：issue #8262 里它显示成 `6.0 MBit/s`，
本机实测则是**干脆不报告**。两种都不代表实际速率。

**判断标准只有一个：iperf3 实测吞吐。**

---

## 相关链接

- [OpenWrt issue #8262 — ath10k-ct will not TX above 40MHz width](https://github.com/openwrt/openwrt/issues/8262)
- [greearb/ath10k-ct](https://github.com/greearb/ath10k-ct)（CT 驱动与固件上游）
- 本目录 `hardware-notes.md` — 完整硬件实测笔记（射频能力、功率、overlay whiteout 等）
- 本目录 `packages.md` — 完整包清单
