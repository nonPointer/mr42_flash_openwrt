# Meraki MR42 → OpenWrt 刷机指南（macOS arm64 版）

> 配套脚本: `01_fetch_toolchain.sh`（下载+校验）、`ubootwrite3.py`（python3 版注入）、
> `tftpd3.py`（零依赖 TFTP 服务器）、`serial_shell.sh`（串口终端）。
> 权威流程来源: [OpenWrt wiki MR42](https://openwrt.org/toh/meraki/mr42)、
> [clayface/openwrt-cryptid](https://github.com/clayface/openwrt-cryptid)、
> [hayao0819 批量刷机实录](https://hayao0819.com/blog/posts/20241123/mr42-openwrt/)（2024-11，10 台）。
> 完整工具链 sha256 表见同目录 `TOOLCHAIN_SHA256.md`。
>
> ## ⚡ 先读这里：两条路线怎么选
>
> | | 免拆机（**第 8 节**） | 拆机串口（第 2/4/5 节） |
> |---|---|---|
> | 前提 | 能进诊断模式（按 reset 后**蓝灯**） | 诊断模式进不去时的后路 |
> | 工具 | `02_flash_uboot_diagnostic.sh` → `03_flash_openwrt.sh` | `ubootwrite3.py` + `serial_shell.sh` |
> | 状态 | **2026-08-20 端到端实测走通** | 未在本机验证 |
>
> **先试免拆机。** 能进诊断模式就完全不需要拆机、不需要串口、不需要 pyserial。
> 诊断模式下 u-boot 就已写好，第 5 节（initramfs 内写 mtd8）也一并跳过。

---

## 0. 硬件清单

| 物品 | 说明 |
|---|---|
| MR42 ×1 | 已确认固件版本（见第 1 步，**先看再拆！**） |
| USB-TTL 3.3V 串口适配器 | CP2102 推荐（Silicon Labs 有 arm64 原生驱动）；PL2303/CH340 也行但要装对驱动 |
| 杜邦线 ×3 | TXD / RXD / GND |
| 网线 + 交换机/路由器 | 电脑网口 → 交换机 → AP（**不要电脑直连 AP**，社区实测直连 TFTP 反复失败） |
| 螺丝刀 | 拆橡胶脚垫下的螺丝 |
| 12V 电源 | 或用 PoE 交换机供电 |

macOS 驱动（Apple Silicon 必须 arm64 原生版）:
- CP2102: [Silicon Labs VCP 驱动](https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers)（Universal 版）
- PL2303: [Prolific 官方驱动](https://www.prolific.com.tw/US/ShowProduct.aspx?p_id=229&pcid=41)（macOS 13+ 必须装新版，老 kext 已被系统移除）
- CH340: WCH 官网驱动

装完驱动后插入适配器，检查:
```bash
ls /dev/cu.usbserial-*     # 能看到设备 = 驱动 OK
```

---

## 1. 🔴 第一件事：确认固件版本（决定你能不能软刷）

**只有老固件能 UART 软刷。** 新固件（2020-11 之后）把 u-boot 的中断口令 xyzzy 干掉了，
ubootwrite 会永远等不到提示符——**任何软件方法都救不了，只能拆 NAND 编程器**。
所以刷机前必须先看版本，别白拆。

**怎么看：** 接好串口（第 2 步）后上电，在启动日志里找一行:

```
Bootkernel Meraki Build is 25-201809040933-G8fbce340-...
```

| 启动日志 | 结论 |
|---|---|
| `25-20180904xxxx` 或更早 | ✅ 老固件，按本指南 UART 软刷 |
| `25-202011091102` 或更新 | 🔴 xyzzy 已失效（[实测案例 t/142218](https://forum.openwrt.org/t/installing-openwrt-on-meraki-mr42/142218)），只能 NAND 编程器换 u-boot，或换一台老固件机器 |

旁证：主系统版本 `Linux 3.14.79` = 老；`Linux 4.4.302-meraki`（2022-12）= 新。
另外启动日志出现 `Booting part.safe` 说明这台连免拆诊断模式都没有（[RoganDawes 2024-02](https://forum.openwrt.org/t/installing-openwrt-on-meraki-mr42/142218)）。

⚠️ 还有个例外：**MR52 上 2021 年仍有 bootkernel 25-202011091102 成功刷机的案例**（wiki 完整流程），
所以 bootkernel 版本与 xyzzy 可用性并非严格一一对应（社区猜测未经证实）。MR42 上保守起见按上表判断。

---

## 2. 拆机 + 接 UART

拆机顺序（[hayao0819 照片最全](https://hayao0819.com/blog/posts/20241123/mr42-openwrt/)）:
1. 撕掉底部 4 个橡胶脚垫 → 露出隐藏螺丝，拧下
2. 撬开白色面盖（卡扣）
3. 取下灰色背板 → 金属块
4. 主板侧面共 10 颗螺丝

UART 焊盘在板上，4 孔:

```
1 = 3.3V (VCC, 方形焊盘标记) | 2 = TXD | 3 = RXD | 4 = GND
```

**⚠️ 只接 TXD / RXD / GND 三根线。接 3.3V 会烧板。**
（wiki 照片写 L→R 为 GND,RX,TX,VCC，与编号表方向相反——两处矛盾，有条件用万用表确认；
保守做法：只碰 TX/RX/GND，3.3V 那个脚永远不接。）

接线对应关系:

| 适配器 | → | AP |
|---|---|---|
| RXD | ← | TXD (2) |
| TXD | → | RXD (3) |
| GND | — | GND (4) |

两个坑:
- 跳线尖可能碰到金属外壳短路 → **板下垫一张纸/便利贴绝缘**（顺手写上引脚定义）
- 塑料导光脚易折断 → 热熔胶修复（少涂，盖盖会顶）

---

## 3. 准备（一次性）

### 3.1 下载工具链（全部 sha256 校验，防止刷入被篡改的固件）

```bash
cd mr42-flash
./01_fetch_toolchain.sh          # 下载到 ./toolchain/，任一校验失败立即中止
```

### 3.2 建 python3 环境（ubootwrite3.py 需要 pyserial）

```bash
python3 -m venv .venv
.venv/bin/pip install pyserial
```

### 3.3 电脑固定 IP + 启动 TFTP

**静态 IP:** 系统设置 → 网络 → 当前网口（Wi-Fi/以太）→ 详细信息 → TCP/IP →
配置 IPv4 = 手动 → `192.168.1.250` / 子网掩码 `255.255.255.0`（路由器留空即可，刷机时不需要网关）。

**TFTP 服务器:** macOS 内置 tftp 服务器不可用（[hayao0819 实测](https://hayao0819.com/blog/posts/20241123/mr42-openwrt/)），用本包零依赖版:

```bash
cd toolchain
sudo python3 ../tftpd3.py            # 69 端口 <1024 需要 sudo；macOS 会弹防火墙询问，点允许
```

`toolchain/` 里要有: `openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb`（clayface 版，内含 /root/mr42_u-boot.mbn）。

**网络拓扑（重要）:** 电脑 → 交换机/路由器 → AP 网口。
电脑直连 AP 的 TFTP 失败率高（[hayao0819 直连一次没成](https://hayao0819.com/blog/posts/20241123/mr42-openwrt/)）。

### 3.4 打开串口终端（观察用）

```bash
./serial_shell.sh                          # 先看设备名
./serial_shell.sh /dev/cu.usbserial-XXXX   # 115200 8N1
```

上电 AP → 应看到 u-boot banner + 启动日志。**先做第 1 步的版本确认再继续。**

---

## 4. 注入网络版 u-boot（约 13 分钟）

1. 关掉 serial_shell（Ctrl-A K）——串口被占会冲突
2. 确认 tftpd3.py 还在跑，`toolchain/` 里有 clayface 的 `.itb`
3. 运行注入:

```bash
.venv/bin/python ubootwrite3.py --write=toolchain/mr42_u-boot.bin
```

脚本会打印 `Waiting for device...` → **此时给 AP 上电** →
脚本等到 `late_init: machid 4971` 后自动发 xyzzy → 逐 4 字节写入（进度条，~13 分钟）→ 发 `go` 跳转。

⚠️ 注入期间：
- **不要碰桌面/设备**——跳动会导致串口传输中断（中断几次没事，设备回 Meraki 正常，此时还是安全的）
- 看到 u-boot shell 提示符 `(YOWIE)#` = 中断成功

4. 二级 u-boot 启动后自动从 TFTP 拉 initramfs → **AP 白灯常亮 = 成功**。
   TFTP 失败的表现：u-boot 反复重试打印 `TFTP from server ...` 失败。
   对策：确认 tftpd3.py 在跑且文件在目录里；确认网线过交换机；把电脑网口强制 10Mb/s 半双工。

---

## 5. 🔴 MR42 特有：换网络版 u-boot 进 NAND（跳过 = 重启即砖）

clayface 的 initramfs 是**完整救援系统**（2026-08 拆包实测已内置，无需联网安装）:

- `kmod-mtd-rw`（含 `i_want_a_brick` 参数）+ 完整 mtd-utils（nandwrite / nanddump / ubirmvol / ubiupdatevol）
- LuCI 网页界面（`/www/luci-static` 实测存在）、dropbear (ssh/scp)、busybox tftp
- **`/root/mr42_u-boot.mbn` 已预置**（实测确认在 cpio 文件列表中）

→ wiki 的 `opkg install kmod-mtd-rw nand-utils` 步骤可以**整个跳过**（它的 2021 软件源早已下线，
装了反而会卡），而且全程不需要外网，符合第 10 节断网纪律。

initramfs 起来后（白灯常亮），**用串口操作**（此时 AP 的 IP 是 DHCP，串口最稳）:

```bash
./serial_shell.sh /dev/cu.usbserial-XXXX
```

登录（root，无密码）后:

```sh
# 1. 解锁 mtd 写（内核 ≥5.10 + boot_layout ECC 配置，clayface 镜像已满足）
insmod mtd-rw i_want_a_brick=1

# 2. 确认 /root/mr42_u-boot.mbn 存在
ls -l /root/mr42_u-boot.mbn

# 3. 刷 u-boot 到 mtd8（⚠️ initramfs 里 u-boot 是 mtd8；原厂系统里才是 mtd1）
mtd erase /dev/mtd8
nandwrite -pam /dev/mtd8 /root/mr42_u-boot.mbn
```

**必须看到** `Writing data to block 0 at offset 0x0` / `block 1 at offset 0x20000` /
`block 2 at offset 0x40000`。没看到就不要断电，回头查命令和文件。

（备选：若用官方 25.12.5 initramfs 而非 clayface 版，.mbn 不在 /root——
需 `opkg update && opkg install kmod-mtd-rw nand-utils`（25.12.5 软件源还活着），
再 `tftp -gr mr42_u-boot.mbn 192.168.1.250` 把 .mbn 从你的 Mac 拉进 AP）

---

## 6.（可选）删 Meraki OS 卷释放空间

MR42 NAND 128MB，不删的话刷完只剩 ~200KB。删掉 Meraki 系统卷（**在 sysupgrade 之前删**）:

```sh
for i in diagnostic1 part.old storage part.safe; do ubirmvol /dev/ubi0 -N $i; done
```

⚠️ **千万别删 ubi1 的 ART 分区（mtd12）**——无线校准数据，删了 WiFi 报废。

---

## 7. 刷正式固件（🔴 写完 mtd8 后必须先 sysupgrade 再重启，否则砖）

initramfs 自带 LuCI，用网页传最省事（串口日志里会打印 AP 的 IP）:

```text
浏览器打开 http://<AP的DHCP地址>/ → LuCI（root，无密码）→ 系统 → 备份/刷机
→ 选择 openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin → 刷写
```

或命令行（先把 .bin 从 Mac 传过去: `scp .../sysupgrade.bin root@<AP-IP>:/tmp/`，dropbear 已内置）:

```sh
sysupgrade /tmp/openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin
```

重启后 AP 默认 DHCP 拿地址。以后管理就走 LuCI/SSH 了。

---

## 8. ✅ 免拆机诊断模式（2026-08-20 实测走通，**推荐优先尝试**）

> 本节已在一台 bootkernel 老固件的 MR42 上**端到端验证成功**，全程未拆机、未接串口。
> 走这条路时，**第 2/3.4/4 节（拆机、串口、ubootwrite）和第 5 节（initramfs 内写 mtd8）
> 全部跳过** —— u-boot 在诊断模式下就已写好了。
>
> 自动化脚本：`./02_flash_uboot_diagnostic.sh` → `./03_flash_openwrt.sh`

### 8.1 进入诊断模式

1. 上电时按住 reset ~10s → 橙灯开始闪 → 松手 → 连按 reset 两次 → **蓝灯**
2. 电脑网口静态 IP `192.168.1.250`（新 u-boot 的 `serverip` 硬编码就是它）
3. `telnet 192.168.1.1` → 直接 root shell（无密码）

诊断模式下 `/proc/mtd` **只有 4 个分区**（精简 initramfs 只映射了这些），这是正常的：

```
mtd0: 00200000 00020000 "cal"      ← 实为 art 分区（见 8.4）
mtd1: 00180000 00020000 "u-boot"   ← 刷机目标
mtd2: 00010000 00001000 "m25p80"
mtd3: 00136000 0001f000 "ART"
```

### 8.2 写 u-boot（脚本自动完成，含全部防呆）

```bash
cd toolchain && sudo python3 ../tftpd3.py --dir .    # 另开窗口，保持运行
./02_flash_uboot_diagnostic.sh
```

脚本做的事（**手动操作时也必须按这个顺序**）：

```sh
cd /tmp
tftp-hpa 192.168.1.250 -m binary -c get mr42_u-boot.mbn
md5sum mr42_u-boot.mbn          # 必须 0b93ddf7a18a9477620f604b5fc903e1，不对就停手
echo 1 > /sys/devices/platform/msm_nand/boot_layout
flash_erase /dev/mtd1 0 0       # ⚠️ 不要用 `mtd erase`，见 8.3
nandwrite -pam /dev/mtd1 mr42_u-boot.mbn
echo 0 > /sys/devices/platform/msm_nand/boot_layout
```

> 🔴 **设备自带的 `/etc/update_uboot.sh` 不要直接用**：它没有任何错误检查，
> tftp 失败也照擦不误，而且用的是会崩的 `mtd erase`。

### 8.3 🔴 两个会让人以为"设备砖了"的坑

**坑 1：`mtd erase` 触发内核 Oops，冻死 NAND 控制器**

Meraki 的 3.4 内核在 `part_fill_badblockstats` 有空指针 bug。实测表现：

```
Backtrace:
[<c0269204>] (part_fill_badblockstats+0x0/0x7c) from [<c026a1c8>] (mtdchar_ioctl+0x550/0xd10)
---[ end trace 9d2db1b0e5962fa5 ]---
```

之后 `mtd erase` 进程卡死在 **D 状态**（不可中断睡眠，`kill -9` 无效），**握着 NAND 锁不放**，
任何后续 NAND 读写全部挂住。用户态无法解锁，**只能断电**。

- 用 `flash_erase /dev/mtd1 0 0` 代替，走不同 ioctl 路径，实测正常
- **触发条件是并发访问**：不要在擦写进行中另开一个 telnet 去 `nanddump` 看进度。
  所有 NAND 操作必须在**单个会话**里顺序完成

**坑 2：新 u-boot 请求的 initramfs 文件名和仓库里的不一样**

写进 NAND 的 u-boot 环境变量实测是：

```
fit_uimage_initramfs=openwrt-ipq806x-generic-initramfs-fit-uImage.itb   ← 无 meraki_mr42-
serverip=192.168.1.250
ipaddr=192.168.1.100
```

而 clayface 仓库里的文件叫 `openwrt-ipq806x-generic-**meraki_mr42-**initramfs-fit-uImage.itb`。
**名字对不上 → TFTP 404 → 永远进不了 initramfs**，没串口时表现只是"白灯不亮"，极难定位。

`01_fetch_toolchain.sh` 已自动建好该别名。手动的话：

```bash
ln -f toolchain/openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb \
      toolchain/openwrt-ipq806x-generic-initramfs-fit-uImage.itb
```

> 想确认自己这台到底请求什么名字，可回读 u-boot：
> `dd if=/dev/mtd1 bs=64k count=8 | strings | grep fit_uimage_initramfs`

### 8.4 诊断模式 vs 正常模式：mtd 编号与命名完全不同

**写错编号会毁掉别的分区**，务必对照：

| 诊断模式 | 正常/OpenWrt | 说明 |
|---|---|---|
| `mtd1 "u-boot"` | `mtd8 "u-boot"` | **同一块**。诊断模式刷写用 mtd1，wiki 第 5 节的 mtd8 是 initramfs 里的编号 |
| `mtd0 "cal"` | `mtd12 "art"` | **同一块**（实测 md5 完全一致），只是叫法不同 |
| `mtd3 "ART"` | ≈ `ubi1` 的 ART 卷 | 逻辑卷内容，非整分区 |
| `mtd2 "m25p80"` | —（未映射） | SPI flash，**只有诊断模式能 dump** |

### 8.5 网络引导进 initramfs

```
断电 → 按住 reset → 上电 → 【按住 1~2 秒就松手】
```

> 🔴 **别一直按住！** 按太久 OpenWrt 早期会检测到 reset 仍被按下而进入
> **failsafe 模式** —— 没有 ubusd / procd / uhttpd，会导致后面 sysupgrade
> **静默失败**（见第 9 节）。松手早一点，照样能触发 TFTP 引导。

`tftpd3.py` 窗口会打印对 `.itb`（约 9MB）的请求 —— **无串口时这是唯一的进度指示器**。
白灯常亮后：`ssh root@192.168.1.1`（dropbear，首次无密码）。

**此后直接跳到第 6 节（删 UBI 卷）和第 7 节（sysupgrade），或直接跑 `./03_flash_openwrt.sh`。
不需要第 5 节 —— u-boot 已经在 8.2 写好了。**

## 9. 故障排查

| 症状 | 对策 |
|---|---|
| 串口无输出 | TX/RX 接反了对调；确认 GND 接了；驱动没装（见第 0 节） |
| 注入后一直 `Waiting for device...` | 新固件 xyzzy 失效（第 1 步）；或上电太早/太晚——脚本打印 Waiting 后再上电 |
| TFTP 反复失败 | 走交换机不直连；tftpd3.py 目录对不对（.itb 是否在）；强制 10Mb/s 半双工；`sudo` 了吗 |
| TFTP 提示找不到文件 | 看 u-boot 串口输出它请求的文件名（`TFTP from server ... filename`），把那个名字的文件放进 tftpd3.py 的目录（一般就是 clayface 的 `openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb`） |
| 注入中断/断电 | 没事，设备回 Meraki 原状，重来 |
| 白灯但不进 initramfs | TFTP 文件不对 → 用 clayface 的 initramfs（sha256 见 TOOLCHAIN_SHA256.md） |
| `mtd erase` 报错 | 没 insmod mtd-rw；或内核太老（clayface 5.10 镜像没问题） |
| 刷完 mtd8 重启变砖 | 没 sysupgrade 就重启了——只能 NAND 编程器救（见下） |
| **sysupgrade 打印 "Commencing upgrade" 后什么都没发生** | **进了 failsafe，没有 ubusd**。sysupgrade 最后一步是 `ubus call system sysupgrade` 交给 procd，连不上 ubus 就静默失败（设备不重启、版本不变，极易误判为"正在刷"）。修：`ubusd &` 后重试；仍不行则绕过 procd 直接 `export IMAGE=/tmp/xxx.bin INTERACTIVE=0 VERBOSE=1; sh /lib/upgrade/do_stage2`。`03_flash_openwrt.sh` 已自动处理 |
| `mtd erase` 卡死、之后所有 NAND 操作都挂 | 内核在 `part_fill_badblockstats` Oops，进程卡 D 状态握锁不放，**用户态无法解锁，只能断电**。改用 `flash_erase`，且擦写期间**单会话**操作（见 8.3） |
| u-boot 反复 TFTP 失败 / 白灯不亮 | 多半是**文件名不匹配**：u-boot 请求的是不带 `meraki_mr42-` 的名字（见 8.3 坑 2）。回读确认：`dd if=/dev/mtd1 bs=64k count=8 \| strings \| grep fit_uimage_initramfs` |
| initramfs 里没有 uhttpd / LuCI 打不开 | failsafe 模式不启动 uhttpd。刷机用命令行即可（`03_flash_openwrt.sh`），或重新引导时**早点松开 reset** |
| `setsid: not found` / `nohup` 不存在 | busybox 精简版没有。用 `sh -c 'trap "" HUP; ...'` 防 SIGHUP |
| busybox `nc -w` 报 usage | 老 busybox 的 nc 不支持 `-w`。传文件用 `nc IP PORT < file`（设备作客户端），Mac 侧 `nc -l PORT > file` 接收 |

## 10. 🔴 砖机风险与纪律

- **全程断外网**。Meraki 云能远程锁机/覆盖固件（MR18 血泪教训: "DO NOT ALLOW THE DEVICE TO TOUCH THE INTERNET DURING THIS PROCESS"）。刷机期间 AP 只连你的 TFTP 网段
- **写完 u-boot → 必须一路做到 sysupgrade 完成**，中途只能用 reset 网络引导，普通重启 = 砖
  - 注意这个中间态的本质：**新 bootloader 已就位，但 NAND 里没有它能启动的系统**
    （Meraki 卷若已删、OpenWrt 又还没刷）。u-boot 本身写进 flash 后是**永久有效**的，
    断电不丢；危险的是"锁换了但屋里没家具"
  - 只要 u-boot 完好，**按住 reset 上电走 TFTP 引导总能救回来** —— 别急着拆机
- 想保留原厂固件：刷前先 `cat /proc/mtd` 逐个 `nanddump` 备份（原厂完整 dump 全网无人公开）
- 真砖了（新固件 xyzzy 死 + 误操作）：唯一出路 = 拆 TSOP48 NAND 编程器写回老 u-boot（参考 MR33 同款方案，30+ 台验证），或 JTAG（IPQ8068 焊盘未焊，无公开教程，难）
- MR42 无 secure boot fuse，换 u-boot 不会触发硬件锁——这是它比 MR33/MR44 好刷的根本原因

## 11. MR52 差异（如你刷 MR52）

- 流程完全相同，**跳过第 5 步换 u-boot**（wiki 明确标注 MR42 only；MR52 出厂 u-boot 已够用）
- 拆机: 4 个橡胶脚垫藏螺丝 → 铝壳两半撬开，散热硅胶垫保留
- 双网口: 刷后默认 PD 口=lan0，另一口=WAN；硬件版本差异可能导致 PD 口互换，高处部署前先地面测
- 镜像用 mr52 版（本包已含）

## 12. 参考链接

- OpenWrt wiki MR42: https://openwrt.org/toh/meraki/mr42 （`?do=export_raw` 可拿原始 wikitext）
- OpenWrt wiki MR52: https://openwrt.org/toh/meraki/mr52
- clayface/openwrt-cryptid（工具+镜像+校验值）: https://github.com/clayface/openwrt-cryptid
- hayao0819 2024-11 批量刷机（拆机照片/TFTP 走路由器/macOS tftp 不行）: https://hayao0819.com/blog/posts/20241123/mr42-openwrt/
- nanotech 2023-11 最全操作备忘: https://nanotech.hatenablog.jp/entry/2023/11/14/101033
- Qiita 2022-08 u-boot 降速命令: https://qiita.com/2hobata/items/bb066425deee89ea4acc
- 论坛 xyzzy 失效讨论: https://forum.openwrt.org/t/installing-openwrt-on-meraki-mr42/142218
- krishnendu 2021-10 免拆机路线（Windows）: https://krishnendu.com/cisco-meraki-m42-wifi-router-openwrt-custom-firmware/
