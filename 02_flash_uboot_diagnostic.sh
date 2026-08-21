#!/bin/bash
# ============================================================
# 02_flash_uboot_diagnostic.sh
#   免拆机（Meraki 诊断模式 / telnet）把 cryptid 网络版 u-boot 刷进 NAND。
#   对应 guide 第 8 节 = OpenWrt wiki "方法一"，全程不需要串口。
#
#   用法: ./02_flash_uboot_diagnostic.sh [toolchain目录，默认 ./toolchain]
#
#   前提:
#     1. AP 已进诊断模式（按住 reset 上电 ~10s → 松手 → 连按 reset 两次 → 蓝灯）
#     2. Mac 网口静态 IP = 192.168.1.250（新 u-boot 硬编码 serverip 就是它）
#     3. 已在 toolchain/ 目录跑起 tftpd3.py（sudo，69 端口）
#
#   本脚本会把所有操作放在【单个 telnet 会话】里完成 —— 这是硬性要求，
#   见下方 "并发访问" 说明。
# ============================================================
set -uo pipefail

DEST="${1:-toolchain}"
AP=192.168.1.1
MYIP=192.168.1.250
MBN=mr42_u-boot.mbn
MBN_MD5=0b93ddf7a18a9477620f604b5fc903e1

red()  { printf "\033[31m%s\033[0m\n" "$*"; }
grn()  { printf "\033[32m%s\033[0m\n" "$*"; }
ylw()  { printf "\033[33m%s\033[0m\n" "$*"; }
die()  { red "!! $*"; exit 1; }

echo "==================================================="
echo " MR42 u-boot 刷写（免拆机 / 诊断模式）"
echo "==================================================="

# ---------- 前置检查（全部通过才动 flash） ----------
echo
echo "[1/5] 前置检查"

command -v expect >/dev/null || die "缺 expect（macOS 自带 /usr/bin/expect）"

ifconfig 2>/dev/null | grep -q "inet ${MYIP} " \
  || die "本机没有 ${MYIP}。新 u-boot 的 serverip 硬编码为该地址，必须先配好静态 IP。"
grn "    ✓ 本机 IP = ${MYIP}"

ping -c1 -t2 "$AP" >/dev/null 2>&1 || die "ping 不通 ${AP}，AP 没进诊断模式？（蓝灯）"
grn "    ✓ ${AP} 可达"

nc -z -G 3 "$AP" 23 2>/dev/null || die "${AP}:23 telnet 未开放，不是诊断模式。"
grn "    ✓ telnet 已开放"

[ -f "$DEST/$MBN" ] || die "找不到 $DEST/$MBN，先跑 ./01_fetch_toolchain.sh"
got=$(md5 -q "$DEST/$MBN" 2>/dev/null || md5sum "$DEST/$MBN" | awk '{print $1}')
[ "$got" = "$MBN_MD5" ] || die "$MBN md5 不符：期望 $MBN_MD5，实得 $got"
grn "    ✓ $MBN md5 正确"

# tftp 服务必须真的能取到文件 —— 光看端口开着不够
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
( cd "$tmpd" && tftp "$MYIP" >/dev/null 2>&1 <<TFTPEOF
binary
get $MBN probe.mbn
quit
TFTPEOF
) || true
[ -s "$tmpd/probe.mbn" ] || die "TFTP 自测失败：取不到 $MBN。tftpd3.py 起了吗？服务目录对吗？
    正确起法: cd $DEST && sudo python3 ../tftpd3.py --dir ."
probe=$(md5 -q "$tmpd/probe.mbn")
[ "$probe" = "$MBN_MD5" ] || die "TFTP 取回的文件 md5 不符，服务目录里可能是旧文件"
grn "    ✓ TFTP 服务可用（自测取回 $MBN 成功）"

# 引导用的 initramfs 也要就位，否则刷完 u-boot 无法网络引导 = 中间态卡死
ITB_REQUESTED=openwrt-ipq806x-generic-initramfs-fit-uImage.itb
[ -f "$DEST/$ITB_REQUESTED" ] || die "缺 $DEST/$ITB_REQUESTED
    ⚠️ u-boot 请求的正是这个【不带 meraki_mr42- 】的名字。
    重跑 ./01_fetch_toolchain.sh 会自动建好该别名。"
grn "    ✓ 引导用 initramfs 就位（$ITB_REQUESTED）"

# ---------- 风险确认 ----------
echo
ylw "[2/5] ⚠️  接下来的操作不可逆"
cat <<'WARN'
    写入新 u-boot 后，设备将处于「新 bootloader 已就位、但 NAND 里没有
    可启动系统」的中间态。此时【普通重启 = 变砖风险】，必须一路做到
    sysupgrade 完成才安全。

    执行期间：
      • 不要断电
      • 不要开第二个 telnet 去看进度 ← 并发访问 NAND 会触发内核 Oops
        （part_fill_badblockstats），把 NAND 控制器整个冻住
      • 不要碰设备
WARN
printf "确认继续？输入 yes: "
read -r ans
[ "$ans" = "yes" ] || { echo "已取消。"; exit 0; }

# ---------- 单会话完成 get + 校验 + 擦 + 写 + 回读 ----------
echo
echo "[3/5] 写入（单 telnet 会话，请勿打断）"

LOG=$(mktemp)
expect -f - "$AP" "$MYIP" "$MBN" "$MBN_MD5" <<'EXPECT_EOF' 2>&1 | tee "$LOG"
set ap    [lindex $argv 0]
set myip  [lindex $argv 1]
set mbn   [lindex $argv 2]
set md5   [lindex $argv 3]
set timeout 240
log_user 1

spawn telnet $ap
expect -re {# $}

# --- 取固件到设备 /tmp（tmpfs，不碰 NAND） ---
send "cd /tmp; rm -f $mbn\r"
expect -re {# $}
send "tftp-hpa $myip -m binary -c get $mbn; echo GET_RC=$?\r"
expect {
  -re {GET_RC=[0-9]} {}
  timeout { puts "\n>>> FATAL: tftp 取固件超时"; exit 2 }
}
expect -re {# $}

# --- 校验（md5 不对绝不往下走：这是防"擦了却写不进去"的最后一道闸） ---
send "md5sum /tmp/$mbn\r"
expect {
  -re "$md5" { puts "\n>>> md5 校验通过" }
  -re {# $}  { puts "\n>>> FATAL: md5 不符，已中止（NAND 未被触碰）"; exit 3 }
  timeout    { puts "\n>>> FATAL: md5 校验超时"; exit 3 }
}
expect -re {# $}

# --- 打开 bootloader 专用 ECC 布局 ---
send "echo 1 > /sys/devices/platform/msm_nand/boot_layout; echo LAYOUT_ON=$?\r"
expect -re {LAYOUT_ON=[0-9]}
expect -re {# $}

# --- 擦除：用 flash_erase，不用 `mtd erase` ---
#     实测 `mtd erase /dev/mtd1` 会在 part_fill_badblockstats 触发内核 Oops，
#     擦除进程卡死在 D 状态、握着 NAND 锁不放，只能断电恢复。
#     flash_erase 走不同 ioctl 路径，实测正常。
send "flash_erase /dev/mtd1 0 0; echo ERASE_RC=$?\r"
expect {
  -re {ERASE_RC=0}  { puts "\n>>> 擦除完成" }
  -re {ERASE_RC=[0-9]} { puts "\n>>> FATAL: 擦除返回非 0"; exit 4 }
  timeout { puts "\n>>> FATAL: flash_erase 挂住 —— 立即停手，不要重试！\n>>> 请断电重启，重新进诊断模式后再排查。"; exit 4 }
}
expect -re {# $}

# --- 写入 ---
send "nandwrite -pam /dev/mtd1 /tmp/$mbn; echo WRITE_RC=$?\r"
expect {
  -re {WRITE_RC=0} { puts "\n>>> 写入完成" }
  -re {WRITE_RC=[0-9]} { puts "\n>>> FATAL: nandwrite 返回非 0"; exit 5 }
  timeout { puts "\n>>> FATAL: nandwrite 挂住"; exit 5 }
}
expect -re {# $}

send "echo 0 > /sys/devices/platform/msm_nand/boot_layout\r"
expect -re {# $}

# --- 回读验证：确认新 u-boot 的特征串真的落盘了 ---
send "dd if=/dev/mtd1 of=/tmp/vfy.bin bs=65536 count=8 2>/dev/null; strings /tmp/vfy.bin | grep -c 'serverip=192.168.1.250'\r"
expect -re {# $}
send "strings /tmp/vfy.bin | grep 'fit_uimage_initramfs='\r"
expect -re {# $}
send "exit\r"
expect eof
EXPECT_EOF

rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  red "!! 写入流程异常退出（code=$rc），详见上方输出"
  ylw "   若提示 flash_erase/nandwrite 挂住：断电重启 → 重进诊断模式 → 重跑本脚本。"
  ylw "   NAND 控制器一旦冻住，用户态无法解锁，只能断电。"
  exit "$rc"
fi

# ---------- 结果核对 ----------
echo
echo "[4/5] 核对回读结果"
if grep -q "serverip=192.168.1.250" "$LOG" || grep -qE "^1$" "$LOG"; then
  grn "    ✓ 新 u-boot 特征串已在 flash 中"
else
  ylw "    ? 未能在输出里确认特征串，请人工核对上方 'fit_uimage_initramfs=' 一行"
fi
# u-boot 请求的文件名以回读结果为准
req=$(grep -o 'fit_uimage_initramfs=[^ ]*' "$LOG" | tail -1 | cut -d= -f2 | tr -d '\r')
if [ -n "$req" ]; then
  echo "    u-boot 将请求: $req"
  if [ -f "$DEST/$req" ]; then
    grn "    ✓ 该文件已在 $DEST/"
  else
    red "    !! $DEST/ 里没有 $req —— 引导会失败！"
    ylw "       立即执行: ln -f $DEST/openwrt-ipq806x-generic-meraki_mr42-initramfs-fit-uImage.itb $DEST/$req"
  fi
fi
rm -f "$LOG"

# ---------- 下一步 ----------
echo
echo "[5/5] 下一步（现在处于中间态，务必继续）"
cat <<NEXT

    1) 断电 → 按住 reset → 上电 → 【按住 1~2 秒就松手】
       ⚠️ 别一直按住！按太久 OpenWrt 会进 failsafe（无 ubus），
          会导致后面 sysupgrade 静默失败。松手早一点即可触发 TFTP 引导。

    2) 看 tftpd3.py 窗口：应出现对
       $ITB_REQUESTED 的请求（约 9MB）。
       没串口时这是唯一的进度指示器。

    3) 等白灯常亮 → OpenWrt initramfs 起来了，此时 AP 仍是 192.168.1.1
       ssh root@192.168.1.1  （dropbear，首次无密码）

    4) 跑 ./03_flash_openwrt.sh 完成正式固件刷写。

NEXT
grn "u-boot 写入完成。"
