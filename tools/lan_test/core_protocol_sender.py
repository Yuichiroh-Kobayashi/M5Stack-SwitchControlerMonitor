#!/usr/bin/env python3
"""Act as the Wireless-compatible TCP sender for LANReceiver testing."""

from __future__ import annotations

import argparse
import socket
import time


NEUTRAL = "00,00,00,80,80,80,80"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="192.168.50.20")
    parser.add_argument("--port", type=int, default=12345)
    parser.add_argument("--accept-timeout", type=float, default=15.0)
    parser.add_argument("--tail-duration", type=float, default=5.0)
    return parser.parse_args()


def send_line(client: socket.socket, label: str, record: str | bytes) -> None:
    payload = record.encode("ascii") if isinstance(record, str) else record
    client.sendall(payload + b"\n")
    print(f"send={label} length={len(payload)} data={payload!r}")
    time.sleep(0.05)


def main() -> int:
    args = parse_args()
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(1)
    server.settimeout(args.accept_timeout)
    print(f"listening={args.bind}:{args.port}")
    try:
        client, peer = server.accept()
    except socket.timeout:
        print("accept=TIMEOUT")
        return 2
    finally:
        server.close()

    print(f"accept=OK peer={peer[0]}:{peer[1]}")
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        send_line(client, "neutral", NEUTRAL)
        send_line(client, "all_primary_buttons", "FF,00,00,80,80,80,80")
        send_line(client, "all_secondary_buttons", "00,3F,00,80,80,80,80")
        for wire_dpad in range(1, 9):
            send_line(
                client,
                f"dpad_hat_{wire_dpad - 1}",
                f"00,00,{wire_dpad:02X},80,80,80,80",
            )
        send_line(client, "axes_min", "00,00,00,00,00,00,00")
        send_line(client, "axes_center", NEUTRAL)
        send_line(client, "axes_max", "00,00,00,FF,FF,FF,FF")

        # Invalid records are deliberately not part of the product protocol.
        send_line(client, "invalid_size", b"BAD")
        send_line(client, "invalid_magic_not_applicable", b"M5DS,00")
        send_line(client, "invalid_version_not_applicable", b"VERSION,02")
        send_line(client, "invalid_dpad", "00,00,09,80,80,80,80")
        send_line(client, "overflow", b"A" * 80)

        # There is no sequence field in the reused Wireless record. Repeated
        # records test duplicate delivery; reverse/jump cases are N/A.
        send_line(client, "duplicate_1", NEUTRAL)
        send_line(client, "duplicate_2", NEUTRAL)
        print("sequence_duplicate/reverse/jump=N/A (no sequence field)")

        send_line(client, "pre_timeout_neutral", NEUTRAL)
        print("pause=350ms expected_receiver_timeout=100ms")
        time.sleep(0.35)
        send_line(client, "resume_after_timeout", NEUTRAL)

        deadline = time.monotonic() + args.tail_duration
        tail_count = 0
        while time.monotonic() < deadline:
            client.sendall((NEUTRAL + "\n").encode("ascii"))
            tail_count += 1
            time.sleep(0.02)
        print(f"tail_neutral_count={tail_count}")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
