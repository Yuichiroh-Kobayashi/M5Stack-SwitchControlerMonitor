#!/usr/bin/env python3
"""Receive the existing PS5 CoRE newline-delimited TCP protocol."""

from __future__ import annotations

import argparse
import re
import socket
import time
from dataclasses import dataclass, field


CANONICAL_RECORD = re.compile(
    rb"^[0-9A-Fa-f]{2}(?:,[0-9A-Fa-f]{2}){6}$"
)


def percentile_nearest_rank(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * percentile + 0.999999) - 1))
    return ordered[index]


def format_ms(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.3f} ms"


@dataclass
class Stats:
    connections: int = 0
    disconnects: int = 0
    received: int = 0
    valid: int = 0
    invalid: int = 0
    neutral: int = 0
    non_neutral: int = 0
    last_record_at: float | None = None
    intervals_ms: list[float] = field(default_factory=list)

    def observe_valid(self, now: float) -> float | None:
        interval = None
        if self.last_record_at is not None:
            interval = (now - self.last_record_at) * 1000.0
            self.intervals_ms.append(interval)
        self.last_record_at = now
        return interval

    def reset_stream_timing(self) -> None:
        self.last_record_at = None


def decode_record(line: bytes) -> tuple[int, ...] | None:
    if len(line) != 20 or not CANONICAL_RECORD.fullmatch(line):
        return None
    return tuple(int(field, 16) for field in line.split(b","))


def print_summary(stats: Stats) -> None:
    average = (
        sum(stats.intervals_ms) / len(stats.intervals_ms)
        if stats.intervals_ms
        else None
    )
    maximum = max(stats.intervals_ms) if stats.intervals_ms else None
    p99 = percentile_nearest_rank(stats.intervals_ms, 0.99)
    latest = stats.intervals_ms[-1] if stats.intervals_ms else None
    print("\n=== summary ===")
    print(
        f"connections={stats.connections} disconnects={stats.disconnects} "
        f"received={stats.received} valid={stats.valid} invalid={stats.invalid}"
    )
    print(f"neutral={stats.neutral} non_neutral={stats.non_neutral}")
    print(
        "interval_latest={} interval_max={} interval_avg={} interval_p99={}".format(
            format_ms(latest),
            format_ms(maximum),
            format_ms(average),
            format_ms(p99),
        )
    )
    print("sequence=N/A (the reused Wireless protocol has no sequence field)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sender", default="192.168.50.10")
    parser.add_argument("--port", type=int, default=12345)
    parser.add_argument("--source", default="192.168.50.20")
    parser.add_argument("--duration", type=float, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    stats = Stats()
    started = time.monotonic()
    retry_at = 0.0
    client: socket.socket | None = None
    buffer = bytearray()
    print(f"target={args.sender}:{args.port} source={args.source}")
    try:
        while args.duration is None or time.monotonic() - started < args.duration:
            now = time.monotonic()
            if client is None:
                if now < retry_at:
                    time.sleep(min(0.05, retry_at - now))
                    continue
                candidate = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                candidate.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                candidate.settimeout(0.25)
                try:
                    candidate.bind((args.source, 0))
                    candidate.connect((args.sender, args.port))
                except OSError as error:
                    candidate.close()
                    retry_at = now + 0.25
                    print(f"connect=RETRY error={error}")
                    continue
                client = candidate
                buffer.clear()
                stats.connections += 1
                stats.reset_stream_timing()
                print(f"connect=OK local={client.getsockname()} remote={client.getpeername()}")

            try:
                chunk = client.recv(4096)
            except socket.timeout:
                continue
            except OSError as error:
                print(f"recv=ERROR error={error}")
                chunk = b""
            if not chunk:
                client.close()
                client = None
                stats.disconnects += 1
                retry_at = time.monotonic() + 0.25
                print("connect=DISCONNECTED")
                continue

            buffer.extend(chunk)
            while b"\n" in buffer:
                raw_line, _, remainder = buffer.partition(b"\n")
                buffer = bytearray(remainder)
                line = raw_line.rstrip(b"\r")
                stats.received += 1
                record = decode_record(line)
                if record is None:
                    stats.invalid += 1
                    print(f"record=INVALID length={len(line)} raw={line!r}")
                    continue
                stats.valid += 1
                received_at = time.monotonic()
                interval = stats.observe_valid(received_at)
                byte0, byte1, dpad_wire, lx, ly, rx, ry = record
                dpad = 8 if dpad_wire == 0 else (dpad_wire - 1) & 0x0F
                neutral = record == (0, 0, 0, 0x80, 0x80, 0x80, 0x80)
                if neutral:
                    stats.neutral += 1
                else:
                    stats.non_neutral += 1
                print(
                    "record=OK raw={} buttons0=0x{:02X} buttons1=0x{:02X} "
                    "dpad={} lx={} ly={} rx={} ry={} neutral={} interval={}".format(
                        line.decode("ascii"),
                        byte0,
                        byte1,
                        dpad,
                        lx,
                        ly,
                        rx,
                        ry,
                        1 if neutral else 0,
                        format_ms(interval),
                    )
                )
    except KeyboardInterrupt:
        print("\nCtrl+C received")
    finally:
        if client is not None:
            client.close()
        print_summary(stats)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
