#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# tftpd3.py — 零依赖 TFTP 服务器（RFC1350 + RFC2348 blksize），仅提供读取服务。
#
# 用途: MR42 刷机时给二级 u-boot 提供 initramfs (.itb)。
#       macOS 内置 tftp 服务器不可用（社区实测），本脚本纯 stdlib 实现，无需安装任何包。
#
# 用法:
#   sudo python3 tftpd3.py [--port 69] [--dir <目录，默认当前目录>]
#
# macOS 上 69 端口 < 1024 需要 root → 必须 sudo（一次性刷机会话，无风险）。
# 客户端 (AP 的 u-boot) 固定连 69 端口，所以不要改端口（除非测试）。
# 只允许读取当前目录/--dir 下的文件（拒绝路径穿越），文件名按 basename 处理。
#
# 协议要点:
#   - RRQ octet 模式，默认 512B 块；客户端请求 blksize 选项时协商 (8~1468)
#   - lockstep: 发 DATA → 等 ACK → 超时 5s 重发同块（最多 5 次）→ 放弃
#   - 不支持 WRQ（刷机只需读）

import argparse
import os
import socket
import struct
import sys
import time

OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6

ERR_FILE_NOT_FOUND = 1
ERR_ACCESS_VIOLATION = 2
ERR_ILLEGAL_OP = 4
ERR_UNKNOWN_TID = 5

DEFAULT_BLOCK = 512
MAX_BLOCK = 1468
ACK_TIMEOUT = 5.0
MAX_RETRIES = 5


def log(msg):
    print("[tftpd3] %s" % msg, flush=True)


def send_error(sock, addr, code, msg):
    sock.sendto(struct.pack("!H", OP_ERROR) + struct.pack("!H", code) +
                msg.encode() + b"\x00", addr)


def parse_rrq(data):
    """解析 RRQ: filename \0 mode \0 [opt \0 val \0 ...]，返回 (filename, mode, opts)"""
    parts = data.split(b"\x00")
    if len(parts) < 3:
        return None, None, {}
    filename = parts[0].decode("utf-8", errors="replace")
    mode = parts[1].decode("utf-8", errors="replace").lower()
    opts = {}
    i = 2
    while i + 1 < len(parts) and parts[i]:
        key = parts[i].decode("utf-8", errors="replace").lower()
        val = parts[i + 1].decode("utf-8", errors="replace")
        opts[key] = val
        i += 2
    return filename, mode, opts


def handle_client(sock, data, addr, serve_dir):
    filename, mode, opts = parse_rrq(data[2:])  # 剥掉 2 字节 opcode
    if filename is None:
        send_error(sock, addr, ERR_ILLEGAL_OP, "Bad RRQ")
        return
    if mode != "octet":
        send_error(sock, addr, ERR_ILLEGAL_OP, "Only octet mode supported")
        return

    # 防路径穿越：只取 basename，且必须存在于 serve_dir
    safe = os.path.basename(filename)
    path = os.path.join(serve_dir, safe)
    if not os.path.isfile(path):
        send_error(sock, addr, ERR_FILE_NOT_FOUND, "File not found: %s" % safe)
        log("RRQ %s -> 文件不存在" % safe)
        return

    block_size = DEFAULT_BLOCK
    options_acked = []
    if "blksize" in opts:
        try:
            want = int(opts["blksize"])
            block_size = min(max(want, 8), MAX_BLOCK)
            options_acked.append(("blksize", str(block_size)))
        except ValueError:
            pass
    # tsize 选项（RFC2349）一并回给老客户端也无害；u-boot 2012 不要求，跳过。

    fsize = os.path.getsize(path)
    log("RRQ %s (%d bytes, blksize=%d) from %s" % (safe, fsize, block_size, addr[0]))

    try:
        f = open(path, "rb")
    except OSError:
        send_error(sock, addr, ERR_ACCESS_VIOLATION, "Cannot open file")
        return

    # 有选项协商 → 先发 OACK；客户端回 ACK(0) 后开始传数据
    if options_acked:
        oack = struct.pack("!H", OP_OACK)
        for k, v in options_acked:
            oack += k.encode() + b"\x00" + v.encode() + b"\x00"
        sock.sendto(oack, addr)
        # 等 ACK 0
        sock.settimeout(ACK_TIMEOUT)
        while True:
            try:
                pkt, _ = sock.recvfrom(2048)
            except socket.timeout:
                send_error(sock, addr, ERR_UNKNOWN_TID, "Timeout waiting for ACK")
                f.close()
                return
            if len(pkt) >= 4 and pkt[0] == 0 and pkt[1] == OP_ACK:
                (blk,) = struct.unpack("!H", pkt[2:4])
                if blk == 0:
                    break
        sock.settimeout(None)

    block = 1
    sent_total = 0

    def send_block(payload, blk):
        """发送一个 DATA 块并等待 ACK，重试 MAX_RETRIES 次。返回 True=已确认"""
        data_pkt = struct.pack("!HH", OP_DATA, blk) + payload
        for attempt in range(MAX_RETRIES):
            sock.sendto(data_pkt, addr)
            sock.settimeout(ACK_TIMEOUT)
            try:
                pkt, _ = sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(pkt) >= 4 and pkt[0] == 0 and pkt[1] == OP_ACK:
                (got,) = struct.unpack("!H", pkt[2:4])
                if got == blk:
                    return True
                if got == ((blk - 1) & 0xFFFF):  # 上一个块的重复 ACK，忽略继续等
                    continue
        return False

    last_chunk_full = False
    while True:
        chunk = f.read(block_size)
        if not chunk:
            break
        if not send_block(chunk, block):
            log("传输中止: 块 %d 无 ACK (client %s)" % (block, addr[0]))
            f.close()
            return
        sent_total += len(chunk)
        last_chunk_full = (len(chunk) == block_size)
        block = (block + 1) & 0xFFFF
        if len(chunk) < block_size:
            break

    if last_chunk_full:
        # 文件大小恰为 block_size 整数倍：最后一块是满块，必须补发 0 字节包
        # 表示传输结束（RFC1350），否则客户端会永远等下一块
        if not send_block(b"", block):
            log("传输中止: 结束包 %d 无 ACK (client %s)" % (block, addr[0]))
            f.close()
            return

    log("完成: %s -> %s (%d bytes, %d blocks)" % (safe, addr[0], sent_total, block - 1))
    f.close()


def main():
    ap = argparse.ArgumentParser(description="Zero-dependency TFTP server (read-only)")
    ap.add_argument("--port", type=int, default=69)
    ap.add_argument("--dir", default=os.getcwd())
    args = ap.parse_args()

    serve_dir = os.path.abspath(args.dir)
    if not os.path.isdir(serve_dir):
        sys.exit("目录不存在: %s" % serve_dir)

    if args.port < 1024 and os.geteuid() != 0:
        print("!! 端口 %d < 1024，需要 root。请用: sudo python3 tftpd3.py [--dir ...]" % args.port)
        sys.exit(1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(None)
    log("TFTP 服务器就绪 0.0.0.0:%d  目录: %s" % (args.port, serve_dir))
    log("MR42 的 u-boot 将从 192.168.1.250:69 拉取 initramfs .itb")
    log("按 Ctrl-C 停止")

    while True:
        sock.settimeout(None)  # 清掉 handle_client 遗留的 ACK 超时设置
        try:
            data, addr = sock.recvfrom(2048)
        except KeyboardInterrupt:
            break
        if len(data) < 2 or data[0] != 0:
            continue
        op = data[1]
        if op == OP_RRQ:
            # 同步处理：刷机场景单客户端、单文件，无并发需求。
            # （共享 socket 多线程会导致 ACK 被主循环抢走——已踩坑）
            try:
                handle_client(sock, data, addr, serve_dir)
            except Exception as e:
                log("处理出错: %s" % e)
        elif op == OP_WRQ:
            send_error(sock, addr, ERR_ILLEGAL_OP, "Read-only server")
        # 其它包（ACK/OACK 串扰）忽略


if __name__ == "__main__":
    main()
