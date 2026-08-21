# 原厂 NAND 固件挖掘笔记

> 素材：`~/Downloads/mr42-nand-backup/factory-nand/`（刷 OpenWrt 前的完整 13 分区 dump）
> 分析日期：2026-08-21

## 分区概览

| 分区 | 大小 | 识别结果 | 实数据占比 |
|---|---|---|---|
| mtd00 sbl1 | 256 KiB | 一级 bootloader | 16.5% |
| mtd01 mibib | 1.25 MiB | 分区表 | 0.1% |
| mtd02 sbl2 | 1.25 MiB | 二级 bootloader | 6.2% |
| mtd03 sbl3 | 2.5 MiB | 三级 bootloader | 4.4% |
| mtd04 ddrconfig | 1.125 MiB | DDR 参数 | ~0% |
| mtd05 ssd | 1.125 MiB | — | ~0% |
| mtd06 tz | 2.5 MiB | TrustZone | 5.0% |
| mtd07 rpm | 2.5 MiB | RPM 固件 | 1.9% |
| mtd08 u-boot | 1.5 MiB | 出厂 u-boot | 16.2% |
| **mtd09 bootkernel1** | 10.5 MiB | **FIT uImage**（FDT v17） | 18.4% |
| mtd10 bootkernel2 | 10.5 MiB | 同上（备份槽，内容一致） | 18.4% |
| **mtd11 ubi** | 70.75 MiB | **UBI**，4 卷 + squashfs + UBIFS | 49.9% |
| mtd12 art | 2 MiB | UBI（单卷 ART，射频校准） | 0.5% |

`mtd11` UBI 卷布局（566 个 PEB）：

```
卷 0: 159 LEB   卷 1: 67 LEB   卷 2: 67 LEB   卷 3: 9 LEB
（对应 diagnostic1 / part.safe / part.old / storage）
内含：squashfs ×2 @0x1630841, 0x1e90841   UBIFS ×1034 节点   JFFS2 ×432
```

## 发现 1：Meraki 内部代号 ↔ 市场型号的完整映射

`mtd09` 的 FIT 里内嵌 4 份板级 DTB，全部使用「神秘生物」代号，**没有一处出现市场型号**：

| 代号 | **市场型号** | compatible | LED GPIO |
|---|---|---|---|
| **Yowie** | **MR42** ⭐ 本机 | `meraki,yowie` + `meraki,cryptid` | orange=**31**, white=**32** |
| Bigfoot | MR52 | `meraki,bigfoot` + `meraki,cryptid` | orange=19, white=26 |
| Sasquatch | MR53 | `meraki,sasquatch` + `meraki,cryptid-aq105` | orange=19, white=26 |
| Wookie | MR84 | `meraki,wookie` + `meraki,cryptid-aq105` | white=26 |

映射关系由 [OpenWrt 提交邮件](http://lists.infradead.org/pipermail/lede-commits/2021-November/012451.html)
与 [WatchMySys 的 Meraki 逆向系列](https://watchmysys.com/blog/2024/04/breaking-secure-boot-on-the-meraki-z3-and-meraki-go-gx20/) 佐证；
本机 DTB 解出的 GPIO（Yowie = 31/32，与另三款的 19/26 不同）与之一致。

Yowie（澳洲野人）、Bigfoot（大脚怪）、Sasquatch（北美野人）、Wookie（星战伍基人）
—— 全是神秘生物主题，平台名 `meraki,cryptid`（cryptid = 神秘动物学中的「未确认生物」）。

**→ 社区破解项目 `clayface/openwrt-cryptid` 的名字，直接沿用了 Meraki 自己的平台代号。**

`cryptid-aq105` 后缀只出现在 Sasquatch(MR53) / Wookie(MR84) 上，应为更新的硬件平台修订。

### 板型间的硬件差异（从 DTB 解出）

| | Yowie(MR42) | Bigfoot(MR52) | Sasquatch(MR53) | Wookie(MR84) |
|---|---|---|---|---|
| `ti,tlc59108` LED 驱动器 | ✅ | ✅ | ✅ | ✅ |
| `atmel,24c64` EEPROM | ✅ | ✅ | ✅ | ✅ |
| **`ina219` 功率监测** | ✅ | ✅ | ✅ | **❌** |
| LED label 数 | 2 gpio + tlc59108 | 同 | 同 | 仅 white |

## 发现 2：原厂固件通篇不含市场型号字符串

```
mtd09-bootkernel1.bin   mr42/mr52 关键字命中: 0
mtd08-u-boot.bin        mr42/mr52 关键字命中: 0
mtd11-ubi.bin           mr42/mr52 关键字命中: 0
```

内核里可枚举到的板型标识只有：

```
meraki,yowie   meraki,bigfoot   meraki,sasquatch   meraki,wookie
meraki,cryptid   meraki,cryptid-aq105   meraki,meraki-config
```

**排查这类设备时，搜市场型号会一无所获，必须先知道代号。**

### 原厂内核与构建信息

```
Linux version 3.4.110 (mprokos@lams) (gcc version 4.8.3 (GCC))
  #2 SMP Wed Jan 13 14:13:02 PST 2016

Bootkernel FIT uImage
24-189947M-gf4598ac1-mprokos
```

- 内核 **3.4.110**，2016-01 构建，构建者 `mprokos@lams`（与 bootkernel 版本串同源）
- Bootkernel 版本 `24-` 开头，比 OpenWrt wiki 判定「老固件」的门槛 `25-201809040933` **还老**
  —— 这正是本机能进免拆机诊断模式的原因
- 内核映像以 **XZ** 压缩内嵌于 FIT（`@0x3ca0`，解出 7,770,948 B）

## 发现 3：Meraki 原厂固件本身就是 OpenWrt 衍生版

内核里残留的**编译器搜索路径**是铁证：

```
/home/mprokos/work/router2/openwrt/staging_dir_arm_nofpu_qca_3.4/...
/home/mprokos/work/router2/openwrt/toolchain_build_arm_nofpu_qca_3.4/uClibc-0.9.33.2
                            ^^^^^^^
```

`staging_dir_*` / `toolchain_build_*` 是 **OpenWrt 构建系统独有的目录命名**，
Buildroot / Yocto 都不是这个结构。开发者 `mprokos` 的工作树里，OpenWrt 就放在 `router2/openwrt/`。

内核源码树则是 `/home/mprokos/work/router2/linux-qca-3.4/`（高通的 3.4 内核分支）。

### 血统链

```
OpenWrt（上游）
   ↓
Qualcomm QSDK（高通基于 OpenWrt 定制的芯片 SDK）
   ↓  DISTRIB_ID="QSDK"   DISTRIB_TARGET="ipq806x/generic"
   ↓  DISTRIB_CODENAME="enterprise_ap160"
Meraki 定制（/home/mprokos/work/router2/）
   ↓
MR42 原厂固件
```

### 其他佐证

- 诊断模式的 `/etc/openwrt_release` 字段格式（`DISTRIB_ID` / `DISTRIB_TARGET` /
  `DISTRIB_REVISION`）**就是 OpenWrt 的**
- `DISTRIB_TARGET="ipq806x/generic"` —— 与现在刷的 OpenWrt 25.12.5 **target 名完全一致**
- `BusyBox v1.19.4` + uClibc 0.9.33.2 + ash —— 典型 OpenWrt 组合
- 内核内 `busybox` 字符串命中 140 次、`openwrt` 11 次
- Cisco/Meraki 有 [GPL 源码发布页](https://meraki.cisco.com/support/#policies:gpl)，法律侧印证

**→ 刷机这件事，本质是把一个 2015 年的 OpenWrt 衍生版，换成 2026 年的官方 OpenWrt。**
Meraki 拿 OpenWrt 做底子、加上云管控与签名锁把用户挡在外面；
而 `openwrt-cryptid` 做的就是拆掉这把锁，让设备跑回原本的开源系统。

## 发现 4：UBI 卷必须按 LEB 重组才能提取

**直接按文件偏移切 squashfs 会得到垃圾数据** —— UBI 卷在物理镜像里不是连续的。

每个 PEB（128 KiB）的结构：

```
[EC header 'UBI#'] [VID header 'UBI!'] [数据 = 1 个 LEB, 126976 B]
```

文件系统数据被这些 header 打断。实测直接切出来解析，得到的是
`inodes=522,345,320  mkfs_time=2065-10-28` 这种明显错乱的值。

正确做法：遍历所有 PEB → 读 EC header 拿 `vid_hdr_offset`/`data_offset`
→ 读 VID header 拿 `vol_id`/`lnum` → 按卷分组、按 `lnum` 排序后拼接。

重组后 `mtd11` 的卷内容立刻正常：

| 卷 | 名称 | LEB 数 | 重组后大小 | 内容 |
|---|---|---|---|---|
| 0 | diagnostic1 | 159 | 20,189,184 B | **ARM zImage 内核**（诊断模式系统） |
| 1 | part.safe | 67 | 8,507,392 B | FIT image |
| 2 | part.old | 67 | 8,507,392 B | FIT image |
| 3 | storage | 9 | 1,142,784 B | **UBIFS**（可写配置区） |
| 2147479551 | (layout) | 2 | — | UBI 卷表，跳过 |

> macOS 上没有 `ubireader`，上述重组用约 20 行 Python 即可完成。

## 发现 5：MR42 的 LED 是 GPIO + I2C 两套混合

**先前两次误判，均已修正**：
1. 只看原厂 DTB 里的 `gpio-leds`（2 颗），以为 MR42 只有橙/白两色，
   把「彩色变换」解释成软件效果 —— **错了，是硬件三色 LED**。
2. 据此推论「MR42 不在那 4 份 DTB 里」—— **也错了**。
   原厂 DTB 同样定义了 `ti,tlc59108`，只是我的 strings 过滤太窄漏掉了；
   MR42 就是其中的 **Yowie**。

设备实测（OpenWrt 侧）：

| LED | 驱动 | 硬件路径 |
|---|---|---|
| `orange:power` | GPIO | 直连 SoC |
| `white:active` | GPIO | 直连 SoC |
| **`red:user`** | **I2C** | `16580000.i2c/i2c-1/1-0040` |
| **`green:user`** | I2C | 同上 |
| **`blue:user`** | I2C | 同上 |
| `ath10k-phy0/1/2` | 虚拟 | 射频指示，非物理灯 |

`1-0040` = **TLC59108**，8 路 I2C LED 驱动器，支持 PWM 调光
→ RGB 平滑渐变由它实现；orange/white 只是 GPIO 开关灯。
（对应 `device_packages` 里的 `kmod-leds-tlc591xx`。）

### 命名顺序在两代固件里是反的

```
原厂 DTB :  power:orange   power:white     （功能:颜色）
OpenWrt  :  orange:power   white:active    （颜色:功能）
```

## 发现 6：板上另外两颗 I2C 芯片

扫 `/sys/bus/i2c/devices/` 时顺带发现：

| 地址 | 芯片 | 用途 |
|---|---|---|
| `0-0040` | **INA219** | 电流/功率监测（PoE 供电监控） |
| `0-0056` | **24c64** | 8 KiB EEPROM —— **很可能存 MAC / 序列号 / 板级信息** |
| `1-0040` | TLC59108 | LED 驱动器（见发现 3） |

对应 `device_packages` 里的 `kmod-hwmon-ina2xx` 和 `kmod-eeprom-at24`。

> INA219 意味着可以读实时功耗 —— 值得后续接入 collectd 监控。
> 24c64 EEPROM 值得 dump 出来看看存了什么。

## 发现 7：诊断系统是「几乎未改动的高通 QSDK 参考固件」

从 `mtd11` 卷 0（`diagnostic1`, 20 MB zImage）中解出内核，再从内核里提取出
**内嵌 initramfs（cpio-newc，2642 个条目 / 2138 个文件）**，即诊断模式的完整 rootfs。

```
etc/openwrt_release:
  DISTRIB_ID="QSDK"
  DISTRIB_RELEASE="IPQ806X.LN.1.3.4-CSu2(r00057.1)"
  DISTRIB_CODENAME="enterprise_ap160"     ← 高通 AP160 参考板
  DISTRIB_TARGET="ipq806x/generic"
内核: Linux 3.4.103 (u9611896@WNC-17828) #22 SMP Mon Sep 21 12:54:05 CST 2015
```

### 证据：装了一堆 AP 根本用不到的东西

280 个 opkg 包里包括：

```
cups cups-client libcups*        ← 打印服务器
samba36-server                   ← 文件共享
mplayer libmad libmpg123 libtheora libogg libffmpeg-full   ← 多媒体播放
alsa alsa-utils fdk-aac opencore-amr                       ← 音频编解码
pure-ftpd  quagga(路由协议)  mdadm(RAID)  iozone(磁盘测试)
```

一个吸顶 AP 塞进了打印服务器、Samba 和 MP3 播放器
—— 这是高通给 OEM 的**通用参考板镜像**，Meraki 直接拿来当诊断/救援系统，没有裁剪。

**且全盘搜索无任何 `meraki` / `cryptid` 命名的文件，无证书、无私钥。**
→ 诊断模式压根不是 Meraki 的产品固件，自然也不带任何锁。

### 🔑 免拆机刷机路线的真正成因：root 密码没设

```
etc/shadow:  root:x:0:0:99999:7:::
                  ↑ 密码字段是 "x"

etc/init.d/telnet:
  has_root_pwd() {
      pwd="${pwd#*root:}"; pwd="${pwd%%:*}"
      test -n "${pwd#[\!x]}"      # 为 ! 或 x → 视为「未设密码」
  }
```

**`x` 被判定为未设密码 → 启动 telnetd（而非 dropbear）→ 直接 root shell，无需认证。**

这正是设备 banner 那句提示的由来：

```
Use 'passwd' to set your login password
this will disable telnet and enable SSH
```

**整个免拆机路线，建立在「高通参考固件忘了设 root 密码」这个默认配置之上。**

### 附带的生产测试工具集

```
athdiag  athtestcmd        Atheros 射频诊断 / 测试命令
radartool                  DFS 雷达检测工具
i2cdetect/i2cdump/i2cget/i2cset   I2C 工具（可读写板上 EEPROM）
nandtest  memtester        NAND / 内存测试
ble_conn_test.sh           蓝牙连接测试
led.sh                     LED 控制
ssid_steering (init.d)     高通版客户端引导（dawn 的前身）
```

## 发现 8：ART 分区结构 = 三块 Atheros EEPROM

`mtd12` 同样需按 LEB 重组，得到卷 0（126,976 B，有效数据仅 22,528 B）。
内含三个校准块，间隔固定 0x4000，正好对应三颗射频：

```
0x1000:  20 2f | 61 c7 | 01 01 | XX 8d db 71 ed 9f      ← 射频 1 (3×3)
0x5000:  20 2f | 06 7f | 01 01 | XX 8d db 71 ed 9f      ← 射频 2 (3×3)
0x9000:  44 08 | 07 3f | 04 01 | XX 8d db 71 ed 9f      ← 射频 3 (1×1 扫描)
         长度  | 校验和 | 版本  |  ──── MAC ────
```

标准 **Atheros AR9300 EEPROM 布局**（`eepromVersion` + `templateVersion` + `macAddr[6]`）。

- 三块的后 5 字节 MAC 完全相同，仅首字节不同 —— 同设备三射频共用基础 MAC
- 第三块的长度（`44 08`）与模板版本（`04 01`）都与前两块不同
  —— 正是 1×1 扫描射频（`168c:0050`）与两颗 3×3 QCA9990 的差异

> ⚠️ **隐私提醒**：`mtd12-art.bin` 含设备唯一 MAC。
> 若备份推送到**公开**仓库，等于公开了设备指纹。风险有限（MAC 本就在局域网广播），
> 但介意的话应把仓库设为 private。抹除 MAC 会破坏校验和、令备份失去恢复价值，不建议。

## 发现 9：Meraki 产品系统与「那把锁」🔑

`part.safe` / `part.old`（内容完全相同，sha256 一致）是 **`Cryptid FIT uImage`**，
与诊断系统（QSDK 参考镜像）完全不同 —— 这才是 **Meraki 真正的产品固件**。

### FIT 结构：一份固件通吃四款设备

```
Cryptid FIT uImage
├── kernel@1    "Cryptid Kernel"     1,690,312 B  (Linux 3.4.110 #4)
├── ramdisk@1   "Cryptid Ramdisk"    6,789,204 B lzma → 解出 25.4 MB cpio ← 产品 rootfs
├── fdt@1  "Yowie Device Tree"       ← MR42
├── fdt@2  "Bigfoot Device Tree"     ← MR52
├── fdt@3  "Sasquatch Device Tree"   ← MR53
└── fdt@4  "Wookie Device Tree"      ← MR84
configurations/
└── config@1 "Yowie configuration"（默认）+ config@2..4 各机型
```

u-boot 按硬件选对应 fdt。**这直接实锤 Yowie = MR42**（`config@1` 默认，且是本机唯一无
"Boot Kernel" 字样的配置）。

### 🔑 锁定机制的核心 = 两把 RSA 公钥

产品 rootfs（445 文件）里满是 Meraki 专有组件，其中最关键的：

| 文件 | 作用 |
|---|---|
| **`etc/meraki_pub.rsa`** | **2048-bit RSA 公钥** —— 验证固件签名的信任根 |
| `etc/meraki_test_pub.rsa` | 测试签名公钥 |
| `etc/ssl/meraki-ca.crt` | 云端 TLS CA 证书 |

```
meraki_pub.rsa       Modulus 00:bf:2b:f6:c9:6b:5a:d8...  sha256 6038cbe6…
meraki_test_pub.rsa  Modulus 00:ca:6c:06:e7:9c:5a:78...  sha256 bbb09928…
```

**这就是"锁"**：私钥只在 Meraki 手里，只有 Meraki 签名的固件能通过校验，
所以普通人无法刷入自制固件。

→ **cryptid 的破解思路不是破 RSA（不可能），而是整个换掉 u-boot、连同这套校验逻辑一起绕过**
—— 新 u-boot 根本不验签。也解释了为何刷机第一步必须换 u-boot。

### 云 CA 已于 2020 过期

```
CN = Meraki Certificate Authority, O = Meraki Inc, San Francisco
notAfter = 2020-07-22 GMT   ← 已过期
```

设备用它验证与 Meraki 云的 TLS。证书 2020 年过期 —— 这台老设备即便联网，
证书链也验不过，**间接保护了它没被远程锁死**。

### Meraki 系统架构（从启动脚本与二进制还原）

```
brain                    核心守护进程（设备↔云、执行管控策略；不同板型有 wired_brain 等）
config_updater           固件/配置更新器
mtunnel_client           到云端的管理隧道
mtunnel_http_client
client_eventd            客户端事件上报
board_data_config        读板级 EEPROM（即那颗 24c64）
radclient/radeapclient   RADIUS（企业认证）
merakiclick.ko + click fs  ← 基于 MIT Click 模块化路由器框架
```

- 代码版权 `Meraki, Inc 2007-2012` —— 早于 Cisco 2012 年收购，是原生 Meraki 代码
- **Click 框架**：Meraki 三位创始人皆出自 MIT，产品源于 MIT RoofNet 研究项目
- 支持 x86/powerpc/mips/arm 多板型 —— 全产品线统一固件代码库
- `MERAKI_BUILD = 24-189947M-gf4598ac1-mprokos`（git 短哈希 gf4598ac1 + 开发者 mprokos），
  构建于 2016-01-13；bootkernel(#2)/cryptid(#4)/产品系统三者同一次构建，相隔数十秒

## 发现 10：24c64 EEPROM 的内容结构（免设备，从工具符号还原）

设备已离线读不到 EEPROM 字节，但产品系统里的 `usr/bin/board_data_config`
（C++ 二进制）的符号与字符串直接暴露了它的数据模型：

```
结构体: ar531x_boarddata   （Atheros AR531x 板级数据格式）
字段:
  serial_num              设备序列号
  board_name              板型名
  hwRev                   硬件版本
  enet0Mac / enet1Mac     两个以太网口 MAC
  wlan0Mac / wlan1Mac     两个无线 MAC
  calc_board_data_checksum  校验和
命令: --write-serial / -f（强制写非法序列号）
```

**→ 那颗 24c64（`i2c 0-0056`）存的是设备"出生证"：序列号 + 板型 + 硬件版本
+ 4 个 MAC + 校验和。** 与 ART 分区的射频 MAC 相互独立
（ART 存射频校准用 MAC；EEPROM 存网口/管理 MAC）。

> 要实读：设备在线时 `cat /sys/bus/i2c/devices/0-0056/eeprom | xxd`，
> 或用诊断系统里的 `board_data_config` / `i2cdump 0 0x56`。

## 发现 11：各国射频功率校准模板（呼应实测的功率天花板）

产品 rootfs 的 `lib/firmware/AR900B/hw.2/` 下有一批 QCA9990(AR900B) 校准模板：

```
boardData_AR900B_CUS238_5GMipiMed_v2_003.bin
boardData_AR900B_CUS238_5GMipiHigh_v2_CTL.bin
boardData_AR900B_CUS260_negative_pwr_offset_2G_v2_008.bin
boardData_AR900B_CUS239_negative_pwr_offset_5G_v2_007.bin
...
```

`CUS238/239/260` 是不同客户/地区代号，`negative_pwr_offset` / `High` / `Med`
即各频段的功率上限模板。**这正是决定"某频段最多能干净地发多少 dBm"的底层数据**
—— 呼应实测：AU/ch149 请求 33 dBm、硬件只给 30 dBm，那个 30 就来自这类校准约束。

（另：`www/` 是 Meraki 的 splash / 访客认证本地页面，`meraki_client_api.js`
含 `lat`/`lng`/`speed_test_results_url` 等字段。）

## 发现 12：24c64 EEPROM 实读 —— 设备「出生证」（收官）

设备重新在线后 dump 出 8 KB EEPROM（`i2c 0-0056`），实数据仅 0.6%，
布局与发现 10 从 `board_data_config` 符号推断的完全吻合：

```
0x00  35 33 31 31              magic "5311"（AR531x boarddata 格式）
0x04  12 92                    校验和
0x08  "meraki_Yowie 000000000" board_name  ← Yowie 硬编码在硬件里
0x60  00 18 0a 00 01 02        enet MAC（OUI 00:18:0A = 老 Meraki Inc，2007 注册）
0x66  0c 8d db 71 ed 9f        wlan MAC（OUI 0C:8D:DB = Cisco Meraki，收购后新块）
0x7c  "Q2KDYETQNS47"              序列号（Q2 开头 = 标准 Cisco Meraki 序列号格式）
```

三个收官结论：

1. **Yowie=MR42 的终极实锤** —— 从固件 → DTB → 一路到**硬件 EEPROM**，
   连出厂固件都不需要，芯片自己就记着 `meraki_Yowie`。
2. **序列号 `Q2…`** —— 即 Meraki Dashboard 里添加设备用的那串。
3. **两代 MAC OUI 并存** —— `00:18:0A`（老 Meraki Inc）与 `0C:8D:DB`（Cisco 收购后），
   同一块板上并存，是产品跨越 2012 年收购的痕迹。

符号推断（发现 10）与实读结果一致：`board_name` / `serial_num` /
`enet0Mac` / `wlan0Mac` / checksum 全部对上。

## 挖掘小结

从一份 80 MB 的原厂 NAND 备份，还原出：

1. **三套独立系统**：Meraki 产品固件（Cryptid）、诊断/救援系统（QSDK 参考镜像）、bootkernel
2. **完整代号映射**：Yowie=MR42 / Bigfoot=MR52 / Sasquatch=MR53 / Wookie=MR84，平台 `cryptid`
3. **血统**：原厂固件本身即 OpenWrt 衍生（QSDK → Meraki 定制）
4. **锁定机制**：`meraki_pub.rsa` 2048-bit RSA 固件签名 + 已过期(2020)的云 CA
5. **免拆机后门的根因**：诊断系统 root 密码为 `x`（未设）→ 默认起 telnetd 给 root shell
6. **硬件全貌**：3 射频 + TLC59108(RGB LED) + INA219(功耗) + 24c64(出生证 EEPROM)
7. **功率天花板来源**：ART 分区（3×AR9300 EEPROM）+ AR900B 各国校准模板

所有提取物在 `scratchpad/nand/`（cryptidfs = 产品系统，diagfs = 诊断系统）。
