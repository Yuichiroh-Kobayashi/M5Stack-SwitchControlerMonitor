#!/usr/bin/env python3
"""Receive and validate the 24-byte CoreS3 SE LAN diagnostic packet."""

from __future__ import annotations

import argparse
import datetime as dt
import socket
import struct
import time
from dataclasses import dataclass, field


PACKET = struct.Struct("<4sB3xIIH6B")
MAGIC = b"M5DS"
VERSION = 1


@dataclass
class Stats:
    received: int = 0
    valid: int = 0
    invalid_size: int = 0
    invalid_magic: int = 0
    invalid_version: int = 0
    missing: int = 0
    duplicates: int = 0
    reversed: int = 0
    previous_sequence: int | None = None
    previous_uptime_ms: int | None = None
    previous_received_at: float | None = None
    intervals_ms: list[float] = field(default_factory=list)
    sender_intervals_ms: list[int] = field(default_factory=list)

    def observe_sequence(self, sequence: int) -> str:
        if self.previous_sequence is None:
            self.previous_sequence = sequence
            return "first"
        delta = (sequence - self.previous_sequence) & 0xFFFFFFFF
        if delta == 0:
            self.duplicates += 1
            return "duplicate"
        elif delta < 0x80000000:
            self.missing += delta - 1
            self.previous_sequence = sequence
            return "forward"
        else:
            self.reversed += 1
            # A device reset legitimately restarts the 32-bit sequence. Count
            # the transition once, then use the new stream as the baseline.
            self.previous_sequence = sequence
            return "reversed"

    def observe_sender_uptime(self, uptime_ms: int, sequence_event: str) -> None:
        if sequence_event in ("first", "reversed"):
            self.previous_uptime_ms = uptime_ms
            return
        if sequence_event != "forward" or self.previous_uptime_ms is None:
            return
        delta = (uptime_ms - self.previous_uptime_ms) & 0xFFFFFFFF
        if delta < 0x80000000:
            self.sender_intervals_ms.append(delta)
            self.previous_uptime_ms = uptime_ms

    def observe_interval(self, received_at: float) -> float | None:
        interval = None
        if self.previous_received_at is not None:
            interval = (received_at - self.previous_received_at) * 1000.0
            self.intervals_ms.append(interval)
        self.previous_received_at = received_at
        return interval


def percentile_nearest_rank(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * percentile + 0.999999) - 1))
    return ordered[index]


def format_ms(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.3f} ms"


def print_summary(stats: Stats) -> None:
    average = (
        sum(stats.intervals_ms) / len(stats.intervals_ms)
        if stats.intervals_ms
        else None
    )
    maximum = max(stats.intervals_ms) if stats.intervals_ms else None
    p99 = percentile_nearest_rank(stats.intervals_ms, 0.99)
    latest = stats.intervals_ms[-1] if stats.intervals_ms else None
    sender_average = (
        sum(stats.sender_intervals_ms) / len(stats.sender_intervals_ms)
        if stats.sender_intervals_ms
        else None
    )
    sender_maximum = max(stats.sender_intervals_ms) if stats.sender_intervals_ms else None
    sender_p99 = percentile_nearest_rank(stats.sender_intervals_ms, 0.99)
    sender_latest = stats.sender_intervals_ms[-1] if stats.sender_intervals_ms else None
    print("\n=== summary ===")
    print(f"received={stats.received} valid={stats.valid}")
    print(
        "invalid_size={} invalid_magic={} invalid_version={}".format(
            stats.invalid_size, stats.invalid_magic, stats.invalid_version
        )
    )
    print(
        "sequence_missing={} duplicates={} reversed={}".format(
            stats.missing, stats.duplicates, stats.reversed
        )
    )
    print(
        "interval_latest={} interval_max={} interval_avg={} interval_p99={}".format(
            format_ms(latest),
            format_ms(maximum),
            format_ms(average),
            format_ms(p99),
        )
    )
    print(
        "sender_uptime_interval_latest={} sender_uptime_interval_max={} "
        "sender_uptime_interval_avg={} sender_uptime_interval_p99={}".format(
            format_ms(sender_latest),
            format_ms(sender_maximum),
            format_ms(sender_average),
            format_ms(sender_p99),
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="192.168.50.20")
    parser.add_argument("--port", type=int, default=50000)
    parser.add_argument(
        "--duration",
        type=float,
        default=None,
        help="stop after this many seconds; otherwise run until Ctrl+C",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    stats = Stats()
    started = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.25)
    sock.bind((args.bind, args.port))
    print(f"listening={args.bind}:{args.port} packet_size={PACKET.size}")

    try:
        while args.duration is None or time.monotonic() - started < args.duration:
            try:
                data, source = sock.recvfrom(65535)
            except socket.timeout:
                continue

            received_at = time.monotonic()
            wall_time = dt.datetime.now(dt.timezone.utc).astimezone().isoformat(
                timespec="milliseconds"
            )
            stats.received += 1
            interval = stats.observe_interval(received_at)
            print(
                f"time={wall_time} from={source[0]}:{source[1]} "
                f"length={len(data)} interval={format_ms(interval)}"
            )
            print(f"hex={data.hex(' ')}")

            if len(data) != PACKET.size:
                stats.invalid_size += 1
                print("parse=INVALID_SIZE")
                continue

            (
                magic,
                version,
                sequence,
                uptime_ms,
                button_bits,
                dpad,
                left_x,
                left_y,
                right_x,
                right_y,
                input_valid,
            ) = PACKET.unpack(data)
            if magic != MAGIC:
                stats.invalid_magic += 1
                print(f"parse=INVALID_MAGIC magic={magic!r}")
                continue
            if version != VERSION:
                stats.invalid_version += 1
                print(f"parse=INVALID_VERSION version={version}")
                continue

            stats.valid += 1
            sequence_event = stats.observe_sequence(sequence)
            if sequence_event == "reversed" and stats.intervals_ms:
                # The receiver is intentionally started before the device is
                # reset. Exclude that reboot boundary from continuous-stream
                # interval statistics while still counting the reversal.
                stats.intervals_ms.pop()
            stats.observe_sender_uptime(uptime_ms, sequence_event)
            print(
                "parse=OK magic={} version={} sequence={} uptime_ms={} "
                "input_valid={} button_bits=0x{:04X} dpad={} "
                "left_x={} left_y={} right_x={} right_y={} "
                "received={} missing={} duplicates={} reversed={}".format(
                    magic.decode("ascii"),
                    version,
                    sequence,
                    uptime_ms,
                    input_valid,
                    button_bits,
                    dpad,
                    left_x,
                    left_y,
                    right_x,
                    right_y,
                    stats.received,
                    stats.missing,
                    stats.duplicates,
                    stats.reversed,
                )
            )
    except KeyboardInterrupt:
        print("\nCtrl+C received")
    finally:
        sock.close()
        print_summary(stats)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
