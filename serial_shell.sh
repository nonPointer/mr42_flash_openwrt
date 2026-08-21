#!/bin/bash
# serial_shell.sh — macOS 串口终端（内置 screen，无需装 minicom）
# 用法:
#   ./serial_shell.sh                    # 列出串口设备
#   ./serial_shell.sh /dev/cu.usbserial-ABC123   # 打开串口 @115200 8N1
#
# 常用按键:
#   退出 screen 会话:  Ctrl-A 然后按 K，再按 y
#   暂时脱离(不关闭): Ctrl-A 然后按 D
#   滚动查看输出:     Ctrl-A 然后按 Esc（方向键滚动，q 退出）
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "可用串口:"
  ls -1 /dev/cu.* 2>/dev/null | grep -Ev '^/dev/cu\.(Bluetooth|iBridge|wlan)' || true
  echo
  echo "用法: $0 <串口设备>  例如: $0 /dev/cu.usbserial-ABC123"
  exit 1
fi

PORT="$1"
if [ ! -e "$PORT" ]; then
  echo "!! 设备不存在: $PORT"
  exit 1
fi

echo "打开 $PORT @115200 8N1  (退出: Ctrl-A K, 脱离: Ctrl-A D)"
exec screen "$PORT" 115200
