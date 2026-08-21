#!/bin/bash
# ============================================================
# 03_flash_openwrt.sh
#   在 cryptid OpenWrt initramfs 里完成正式固件刷写（sysupgrade）。
#   用法: ./03_flash_openwrt.sh [toolchain目录，默认 ./toolchain]
#
#   前提: 已通过 02_flash_uboot_diagnostic.sh 换好 u-boot，
#         并已 reset 网络引导进 initramfs（白灯常亮，ssh root@192.168.1.1 可登）
#
#   本脚本处理 2026-08-20 实测踩到的最大的坑：
#     failsafe 模式下没有 ubusd，而 sysupgrade 最后一步是
#     `ubus call system sysupgrade ...` 把刷写交给 procd —— 连不上 ubus 就
#     【静默失败】：只打印 "Commencing upgrade. Closing all shell sessions."
#     然后什么都没发生（设备不重启、版本不变）。极易误判为"正在刷"。
# ============================================================
set -uo pipefail

DEST="${1:-toolchain}"
AP=192.168.1.1
FW=openwrt-25.12.5-ipq806x-generic-meraki_mr42-squashfs-sysupgrade.bin
FW_SHA=c0c4c529997552b32e62357c1cdb097ae3cd74e4d208a7bdd81c9676a7ab6967

red() { printf "\033[31m%s\033[0m\n" "$*"; }
grn() { printf "\033[32m%s\033[0m\n" "$*"; }
ylw() { printf "\033[33m%s\033[0m\n" "$*"; }
die() { red "!! $*"; exit 1; }

CFG=$(mktemp)
trap 'rm -f "$CFG"' EXIT
cat > "$CFG" <<CFGEOF
Host ap
    HostName $AP
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 10
    PubkeyAuthentication no
    PreferredAuthentications password,keyboard-interactive
    HostKeyAlgorithms +ssh-rsa
    KexAlgorithms +diffie-hellman-group14-sha1
    LogLevel ERROR
CFGEOF
sshap() { ssh -F "$CFG" -o BatchMode=yes "$@" ap; }

echo "==================================================="
echo " MR42 正式固件刷写（initramfs 内）"
echo "==================================================="

# ---------- 1. 环境检查 ----------
echo
echo "[1/6] 检查 initramfs 环境"
[ -f "$DEST/$FW" ] || die "找不到 $DEST/$FW，先跑 ./01_fetch_toolchain.sh"
got=$(shasum -a256 "$DEST/$FW" | awk '{print $1}')
[ "$got" = "$FW_SHA" ] || die "固件 sha256 不符"
grn "    ✓ 本地固件校验通过"

board=$(sshap 'cat /tmp/sysinfo/board_name 2>/dev/null' 2>/dev/null | tr -d '\r')
[ -n "$board" ] || die "SSH 连不上 $AP。initramfs 起来了吗（白灯常亮）？"
echo "    board_name: $board"
[ "$board" = "meraki,mr42" ] || ylw "    ? board_name 不是 meraki,mr42，平台脚本可能不匹配"

rel=$(sshap 'grep DISTRIB_RELEASE /etc/openwrt_release' 2>/dev/null | tr -d '\r')
echo "    当前系统: $rel"
sshap 'mount | grep -q " / .*tmpfs"' 2>/dev/null \
  && grn "    ✓ 运行在 initramfs（内存系统）" \
  || ylw "    ? 根文件系统不是 tmpfs，可能已经不是 initramfs"

# ---------- 2. 修复 ubus（本脚本存在的最大理由） ----------
echo
echo "[2/6] 检查 / 修复 ubus"
if sshap 'ubus list >/dev/null 2>&1'; then
  grn "    ✓ ubus 可用"
else
  ylw "    ! ubus 不可用（多半是进了 failsafe）——正在启动 ubusd"
  sshap '(ubusd &) >/dev/null 2>&1; sleep 2' >/dev/null 2>&1
  if sshap 'ubus list 2>/dev/null | grep -q "^system$"'; then
    grn "    ✓ ubusd 已启动，system 对象已注册"
  else
    ylw "    ! ubus 仍不可用 —— 将直接走 do_stage2（见第 5 步）"
  fi
fi
sshap '[ -f /tmp/.failsafe ] && echo "    ! 处于 failsafe 模式" || true' 2>/dev/null

# ---------- 3. 传固件 ----------
echo
echo "[3/6] 传输固件到设备 /tmp"
sshap "cat > /tmp/$FW" < "$DEST/$FW" 2>/dev/null || die "传输失败"
devsha=$(sshap "sha256sum /tmp/$FW" 2>/dev/null | awk '{print $1}' | tr -d '\r')
[ "$devsha" = "$FW_SHA" ] || die "设备端 sha256 不符（传输损坏）：$devsha"
grn "    ✓ 传输完成，设备端 sha256 一致"

# ---------- 4. 删 Meraki UBI 卷 ----------
echo
echo "[4/6] 释放空间（删除 Meraki UBI 卷）"
echo "    不删的话刷完仅剩 ~200KB 可用空间。"
ylw "    ⚠️ 只删 ubi0 上的 Meraki 卷；ubi1 的 ART（射频校准）绝不能碰。"
printf "    删除 diagnostic1/part.old/storage/part.safe？[Y/n]: "
read -r ans
if [ "${ans:-Y}" != "n" ] && [ "${ans:-Y}" != "N" ]; then
  sshap 'for v in diagnostic1 part.old storage part.safe; do
           printf "      %-12s " "$v"; ubirmvol /dev/ubi0 -N "$v" 2>&1 && echo OK
         done
         echo "      剩余可用:"; ubinfo -d 0 2>/dev/null | grep "Amount of available"' 2>&1 | tail -8
  # ART 必须还在
  if sshap 'ubinfo -a 2>/dev/null | grep -q "Name:.*ART"'; then
    grn "    ✓ ART 卷完好"
  else
    die "ART 卷不见了！立即停手，不要继续刷写。"
  fi
else
  ylw "    已跳过（刷完可用空间会非常小）"
fi

# ---------- 5. 刷写 ----------
echo
echo "[5/6] 执行刷写"
ylw "    先试标准 sysupgrade；若因 ubus 不可用而空转，自动回退到 do_stage2。"
echo

before=$(sshap 'cat /proc/uptime | cut -d. -f1' 2>/dev/null | tr -d '\r')

# 方式 A：标准 sysupgrade
timeout 120 ssh -F "$CFG" -o BatchMode=yes -o ServerAliveInterval=10 ap \
  "sysupgrade -F -n /tmp/$FW 2>&1" 2>&1 | tail -12

sleep 8
# 判断是否真的在刷：设备失联 = 正在刷/重启；还能连且 uptime 没断 = 空转了
if sshap 'echo alive' >/dev/null 2>&1; then
  still=$(sshap 'cat /proc/uptime | cut -d. -f1' 2>/dev/null | tr -d '\r')
  if [ -n "$still" ] && [ "${still%.*}" -ge "${before%.*}" ] 2>/dev/null; then
    ylw "    ! sysupgrade 空转了（设备没重启）—— 回退到 do_stage2"
    echo
    # 方式 B：绕过 procd/ubus，直接调用平台刷写函数
    #   do_stage2 = platform_do_upgrade（MR42 → CI_KERNPART=bootkernel2 +
    #   nand_do_upgrade）+ reboot -f。这是官方函数，会正确处理 UBI 卷，
    #   比手动 dd 安全得多（rootfs 必须写成 UBI 卷，dd 会破坏 UBI 结构）。
    #   trap "" HUP 防止 SSH 断开时进程被 SIGHUP 杀掉。
    timeout 300 ssh -F "$CFG" -o BatchMode=yes -o ServerAliveInterval=10 ap \
      "sh -c 'trap \"\" HUP; export IMAGE=/tmp/$FW INTERACTIVE=0 VERBOSE=1; sh /lib/upgrade/do_stage2 2>&1'" 2>&1 | tail -20
  fi
fi

# ---------- 6. 等待新系统 ----------
echo
echo "[6/6] 等待新系统启动"
ok=0
for i in $(seq 1 60); do
  if nc -z -G 1 "$AP" 80 2>/dev/null && nc -z -G 1 "$AP" 22 2>/dev/null; then
    newrel=$(sshap 'grep DISTRIB_RELEASE /etc/openwrt_release' 2>/dev/null | tr -d '\r')
    case "$newrel" in
      *SNAPSHOT*) : ;;                       # 还是 initramfs
      *) ok=1; break ;;
    esac
  fi
  printf "\r    等待中... %ds" $((i*4)); sleep 3
done
echo

if [ "$ok" = "1" ]; then
  echo
  grn "==================== 刷机成功 ===================="
  sshap 'grep -E "DESCRIPTION" /etc/openwrt_release
         echo "型号: $(cat /tmp/sysinfo/model)"
         echo "射频: $(ls /sys/class/ieee80211/ | tr "\n" " ")"
         df -h / | tail -1' 2>/dev/null
  echo
  echo "  管理: http://$AP/   或   ssh root@$AP"
  ylw "  建议立刻设置 root 密码，并关闭 tftpd3.py。"
else
  ylw "    未能在超时内确认新系统。请手动检查："
  echo "      ssh root@$AP 'cat /etc/openwrt_release'"
  echo "    若仍是 SNAPSHOT，说明还在 initramfs，刷写未生效。"
fi
