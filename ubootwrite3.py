#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# ubootwrite3.py — ubootwrite 的 Python 3 移植版（macOS arm64 / Linux 通用）
#
# 原版: clayface/openwrt-cryptid/ubootwrite.py (python2.7, GPLv3)
#   源: https://github.com/HorstBaerbel/ubootwrite (GPLv3)
# 用途: 通过串口把二级 u-boot 上传到 MR42/MR52 的 RAM 并跳转执行。
#       等待设备输出 "late_init: machid 4971" → 发送 xyzzy 中断 autoboot
#       → 逐 4 字节 mw 写入 0x42000000 → go 跳转。全程约 13 分钟。
#
# 移植改动:
#   - python3 语法/bytes 处理 (原版 line161 还有 bytes+str 崩溃 bug，已修)
#   - macOS 串口自动探测 (/dev/cu.*)，Linux 回落 /dev/ttyUSB*
#   - --shell 模式下 prompt 为 None 的崩溃修复
#
# 用法:
#   .venv/bin/python ubootwrite3.py --write=mr42_u-boot.bin
#   .venv/bin/python ubootwrite3.py --write=mr42_u-boot.bin --serial=/dev/cu.usbserial-ABC123 --verbose
#
# ⚠️ 仅老固件 (bootkernel 25-20180904xxxx) 可用；新固件 xyzzy 已失效
#   (bootkernel 25-202011091102+)，注入会永远等不到提示符。

import glob
import optparse
import os
import struct
import sys
import time

debug = False
import serial  # 必需依赖（venv 里 pip install pyserial）

MAX_SIZE = 2 ** 30
LINE_FEED = "\n"


def _candidates():
    """按平台返回候选串口设备列表"""
    if sys.platform.startswith("darwin"):
        pats = [
            "/dev/cu.usbserial-*", "/dev/cu.SLAB_USBtoUART*",
            "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*",
            "/dev/cu.PL2303*", "/dev/cu.USA19H*", "/dev/cu.debug-console*",
        ]
    else:
        pats = ["/dev/ttyUSB*", "/dev/ttyACM*"]
    found = []
    for p in pats:
        found += sorted(glob.glob(p))
    return found


def pick_serial(explicit):
    if explicit:
        return explicit
    cands = _candidates()
    if not cands:
        sys.exit("没有找到串口设备。请插入 USB-TTL 并安装驱动后重试；"
                 "或手动指定 --serial=/dev/cu.xxx")
    if len(cands) > 1:
        print("检测到多个串口，使用第一个: %s" % cands)
        print("如需指定: --serial=<设备>")
    return cands[0]


def getprompt(ser, addr, verbose, shell):
    """等待 u-boot 输出 late_init: machid 4971 并发送 xyzzy 中断"""
    if not shell:
        buf = b""
        while True:
            oldbuf = buf
            buf = ser.read(256)
            combined = (oldbuf + buf).decode("utf-8", errors="replace")
            if "late_init: machid 4971" in combined:
                ser.write(b"xyzzy")
                while ser.read(256):
                    pass
                break

    if verbose:
        print("Waiting for a prompt...")
    while True:
        ser.write(LINE_FEED.encode())
        buf = ser.read(256)
        if buf.endswith(b"> ") or buf.endswith(b"# "):
            print("Prompt is '" + buf[2:].decode("utf-8", errors="replace") + "'")
            return buf
        else:
            while True:
                buf = ser.read(256)
                if buf.endswith(b"> ") or buf.endswith(b"# "):
                    print("Prompt is '" + buf[2:].decode("utf-8", errors="replace") + "'")
                    return buf


def read_until_prompt(ser):
    """没有已知 prompt 时（--shell 模式）读到出现 > 或 # 为止"""
    buf = b""
    while True:
        chunk = ser.read(256)
        if not chunk:
            continue
        buf += chunk
        if buf.endswith(b"> ") or buf.endswith(b"# "):
            return buf[-2:]


def writecommand(ser, command, prompt, verbose):
    ser.write((command + LINE_FEED).encode())
    buf = ser.read(len(command))
    if buf.decode("utf-8", errors="replace") != command:
        if verbose:
            print("Echo command not received. Instead received '" +
                  buf.decode("utf-8", errors="replace") + "'")
        return False

    if verbose:
        print("Waiting for prompt...")

    if prompt is None:
        prompt = read_until_prompt(ser)
    else:
        buf = ser.read(len(prompt))
        if buf != prompt:
            if verbose:
                print("Prompt '" + str(prompt) + "' not received. Instead received '" +
                      str(buf) + "'")
            return False
    if verbose:
        print("Ok, prompt received")
    return True


def memwrite(ser, path, size, start_addr, verbose, debug, shell):
    prompt = None
    if not debug:
        prompt = getprompt(ser, start_addr, verbose, shell)

    if path == "-":
        fd = sys.stdin.buffer
        if size <= 0:
            size = MAX_SIZE
    else:
        fd = open(path, "rb")
        if size <= 0:
            fd.seek(0, os.SEEK_END)
            size = fd.tell()
            fd.seek(0, os.SEEK_SET)

    addr = start_addr
    bytes_read = 0
    startTime = time.time()
    bytesLastSecond = 0
    while bytes_read < size:
        if (size - bytes_read) > 4:
            read_bytes = fd.read(4)
        else:
            read_bytes = fd.read(size - bytes_read)

        # MR33/MR42 的 mw 命令需要每 4 字节反转
        read_bytes = read_bytes[::-1]

        if len(read_bytes) == 0:
            if path == "-":
                size = bytes_read
            break

        bytesLastSecond += len(read_bytes)
        bytes_read += len(read_bytes)

        while len(read_bytes) < 4:
            read_bytes = b"\x00" + read_bytes

        (val,) = struct.unpack(">L", read_bytes)

        str_to_write = "mw {0:08x} {1:08x}".format(addr, val)
        if verbose:
            print("Writing:'" + str_to_write + "' at:", "0x{0:08x}".format(addr))
        if debug:
            str_to_write = struct.pack(">L", int("{0:08x}".format(val), 16))
        else:
            if not writecommand(ser, str_to_write, prompt, verbose):
                print("Found an error, so aborting")
                fd.close()
                return False
            currentTime = time.time()
            if (currentTime - startTime) > 1:
                percent = (bytes_read * 100) / size
                speed = bytesLastSecond / (currentTime - startTime) / 1024
                eta = round((size - bytes_read) / bytesLastSecond / (currentTime - startTime))
                print("\rProgress {0:3.1f}%,  {1:3.1f}kb/s, ETA {2:0}s ".format(
                    percent, speed, eta), end="", flush=True)
                bytesLastSecond = 0
                startTime = time.time()

        addr += 4

    fd.close()

    if bytes_read != size:
        print("Error while reading file '" + fd.name + "' at offset %d" % bytes_read)
        return False
    else:
        print("\rProgress 100%\t\t\t\t")
        writecommand(ser, "go {0:08x}".format(start_addr), prompt, verbose)
        return True


def upload(ser, path, size, start_addr, verbose, debug, shell):
    print("Waiting for device...  (请给 AP 上电)")
    ret = memwrite(ser, path, size, start_addr, verbose, debug, shell)
    print("Done")
    return ret


def main():
    optparser = optparse.OptionParser("usage: %prog [options]",
                                      version="%prog 0.3 mr42 (python3 port)")
    optparser.add_option("--verbose", action="store_true", dest="verbose",
                         help="be verbose", default=False)
    optparser.add_option("--shell", action="store_true", dest="shell",
                         help="already have shell", default=False)
    optparser.add_option("--serial", dest="serial", help="specify serial port",
                         default=None, metavar="dev")
    optparser.add_option("--write", dest="write", help="write mem from file",
                         metavar="path")
    optparser.add_option("--addr", dest="addr", help="mem address",
                         default="0x42000000", metavar="addr")
    optparser.add_option("--size", dest="size", help="# bytes to write",
                         default="0", metavar="size")
    (options, args) = optparser.parse_args()
    if len(args) != 0:
        optparser.error("incorrect number of arguments")

    if not options.write:
        optparser.error("--write 必填 (例如 --write=mr42_u-boot.bin)")

    port = pick_serial(options.serial)

    if not debug:
        ser = serial.Serial(port, 115200, timeout=0.1)
        print("串口: %s @115200 8N1" % port)
    else:
        ser = open(options.write + ".out", "wb")

    if debug:
        prompt = getprompt(ser, 0, options.verbose, options.shell)
        writecommand(ser, "mw 42000000 01234567", prompt, options.verbose)
        buf = ser.read(256)
        print("buf = '" + str(buf) + "'")
        return

    upload(ser, options.write, int(options.size, 0), int(options.addr, 0),
           options.verbose, debug, options.shell)


if __name__ == "__main__":
    main()
