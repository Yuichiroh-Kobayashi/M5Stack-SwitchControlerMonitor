#!/usr/bin/env python3
"""Gate C1 UDP peer with strict validation and offline negative fixtures."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import math
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, TextIO

FRAME_LENGTH = 32
MAGIC = b"C1UD"
VERSION = 1
GATE_ID = 1
DEFAULT_PORT = 50001
FLAG_HORI_READY = 0x01
FLAG_FIXED10HALF_LINK = 0x02
REQUIRED_FLAGS = FLAG_HORI_READY | FLAG_FIXED10HALF_LINK
FORBIDDEN_FLAGS = 0x00
RESERVED_FLAGS = 0xFC


class FrameError(ValueError):
    """Base class for rejected Gate C1 frames."""


class LengthError(FrameError):
    pass


class MagicError(FrameError):
    pass


class VersionError(FrameError):
    pass


class GateError(FrameError):
    pass


class CrcError(FrameError):
    pass


class PayloadError(FrameError):
    pass


class FlagsError(FrameError):
    pass


@dataclass(frozen=True)
class Frame:
    flags: int
    sequence: int
    device_micros: int
    payload: bytes
    crc: int


@dataclass(frozen=True)
class SequenceResult:
    duplicate: bool = False
    out_of_order: bool = False
    gap: int = 0


class SequenceTracker:
    def __init__(self) -> None:
        self.last_sequence: int | None = None

    def observe(self, sequence: int) -> SequenceResult:
        if self.last_sequence is None:
            self.last_sequence = sequence
            return SequenceResult()
        if sequence == self.last_sequence:
            return SequenceResult(duplicate=True)
        delta = (sequence - self.last_sequence) & 0xFFFFFFFF
        if delta == 1:
            self.last_sequence = sequence
            return SequenceResult()
        if 1 < delta < 0x80000000:
            self.last_sequence = sequence
            return SequenceResult(gap=delta - 1)
        return SequenceResult(out_of_order=True)


@dataclass
class PeerSummary:
    expected_source_ip: str
    expected_source_port: int
    require_first_sequence_zero: bool = True
    rx_total: int = 0
    valid_rx_total: int = 0
    crc_error: int = 0
    length_error: int = 0
    format_error: int = 0
    payload_error: int = 0
    unexpected_source: int = 0
    seq_gap: int = 0
    duplicate: int = 0
    out_of_order: int = 0
    flags_error: int = 0
    source_port_error: int = 0
    first_sequence: int | None = None
    last_sequence: int | None = None
    inter_arrivals: list[float] = field(default_factory=list)

    def passed(self) -> bool:
        return (
            self.rx_total > 0
            and self.valid_rx_total > 0
            and (not self.require_first_sequence_zero or self.first_sequence == 0)
            and self.crc_error == 0
            and self.length_error == 0
            and self.format_error == 0
            and self.payload_error == 0
            and self.unexpected_source == 0
            and self.seq_gap == 0
            and self.duplicate == 0
            and self.out_of_order == 0
            and self.flags_error == 0
            and self.source_port_error == 0
        )


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def expected_payload(sequence: int) -> bytes:
    return bytes((sequence + index * 17 + 0x5A) & 0xFF for index in range(14))


def build_frame(sequence: int, device_micros: int, flags: int = REQUIRED_FLAGS) -> bytes:
    frame = bytearray(FRAME_LENGTH)
    frame[0:4] = MAGIC
    frame[4] = VERSION
    frame[5] = GATE_ID
    frame[6] = flags
    frame[7] = FRAME_LENGTH
    frame[8:12] = sequence.to_bytes(4, "big")
    frame[12:16] = device_micros.to_bytes(4, "big")
    frame[16:30] = expected_payload(sequence)
    frame[30:32] = crc16_ccitt_false(frame[:30]).to_bytes(2, "big")
    return bytes(frame)


def validate_flags(flags: int) -> None:
    required_ok = flags & REQUIRED_FLAGS == REQUIRED_FLAGS
    forbidden_ok = flags & FORBIDDEN_FLAGS == 0
    reserved_ok = flags & RESERVED_FLAGS == 0
    if not (required_ok and forbidden_ok and reserved_ok):
        raise FlagsError(
            f"flags {flags:02X}: required={REQUIRED_FLAGS:02X} "
            f"forbidden={FORBIDDEN_FLAGS:02X} reserved={RESERVED_FLAGS:02X}"
        )


def parse_frame(packet: bytes) -> Frame:
    if len(packet) != FRAME_LENGTH:
        raise LengthError(f"packet length {len(packet)} != {FRAME_LENGTH}")
    if packet[0:4] != MAGIC:
        raise MagicError("magic mismatch")
    if packet[4] != VERSION:
        raise VersionError("version mismatch")
    if packet[5] != GATE_ID:
        raise GateError("gate mismatch")
    if packet[7] != FRAME_LENGTH:
        raise LengthError(f"length field {packet[7]} != {FRAME_LENGTH}")
    expected_crc = crc16_ccitt_false(packet[:30])
    actual_crc = int.from_bytes(packet[30:32], "big")
    if actual_crc != expected_crc:
        raise CrcError(f"CRC {actual_crc:04X} != {expected_crc:04X}")
    validate_flags(packet[6])
    sequence = int.from_bytes(packet[8:12], "big")
    device_micros = int.from_bytes(packet[12:16], "big")
    payload = packet[16:30]
    if payload != expected_payload(sequence):
        raise PayloadError("payload mismatch")
    return Frame(packet[6], sequence, device_micros, payload, actual_crc)


def mutate_and_recrc(frame: bytes, offset: int, value: int) -> bytes:
    changed = bytearray(frame)
    changed[offset] = value
    changed[30:32] = crc16_ccitt_false(changed[:30]).to_bytes(2, "big")
    return bytes(changed)


class PacketValidator:
    def __init__(
        self,
        expected_source_ip: str,
        expected_source_port: int,
        require_first_sequence_zero: bool = True,
    ) -> None:
        self.summary = PeerSummary(
            expected_source_ip, expected_source_port, require_first_sequence_zero
        )
        self.tracker = SequenceTracker()
        self.previous_arrival: float | None = None

    def observe(
        self, packet: bytes, source: tuple[str, int], arrival: float
    ) -> dict[str, object]:
        summary = self.summary
        summary.rx_total += 1
        inter_arrival_ms = ""
        if self.previous_arrival is not None:
            interval = (arrival - self.previous_arrival) * 1000.0
            summary.inter_arrivals.append(interval)
            inter_arrival_ms = f"{interval:.6f}"
        self.previous_arrival = arrival
        row: dict[str, object] = {
            "host_timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "source_ip": source[0],
            "source_port": source[1],
            "packet_length": len(packet),
            "sequence": "",
            "device_micros": "",
            "crc": "",
            "payload": "",
            "flags": "",
            "duplicate": 0,
            "out_of_order": 0,
            "gap": 0,
            "inter_arrival_ms": inter_arrival_ms,
            "error": "",
        }
        source_ok = source[0] == summary.expected_source_ip
        port_ok = source[1] == summary.expected_source_port
        if not source_ok:
            summary.unexpected_source += 1
            row["error"] = "unexpected_source"
        if not port_ok:
            summary.source_port_error += 1
            row["error"] = append_error(row["error"], "source_port_error")
        try:
            frame = parse_frame(packet)
            sequence_result = self.tracker.observe(frame.sequence)
            if summary.first_sequence is None:
                summary.first_sequence = frame.sequence
            summary.last_sequence = frame.sequence
            row.update(
                {
                    "sequence": frame.sequence,
                    "device_micros": frame.device_micros,
                    "crc": f"{frame.crc:04X}",
                    "payload": frame.payload.hex().upper(),
                    "flags": f"{frame.flags:02X}",
                    "duplicate": int(sequence_result.duplicate),
                    "out_of_order": int(sequence_result.out_of_order),
                    "gap": sequence_result.gap,
                }
            )
            summary.duplicate += int(sequence_result.duplicate)
            summary.out_of_order += int(sequence_result.out_of_order)
            summary.seq_gap += sequence_result.gap
            if source_ok and port_ok:
                summary.valid_rx_total += 1
        except LengthError as exc:
            summary.length_error += 1
            row["error"] = append_error(row["error"], str(exc))
        except CrcError as exc:
            summary.crc_error += 1
            row["error"] = append_error(row["error"], str(exc))
        except PayloadError as exc:
            summary.payload_error += 1
            row["error"] = append_error(row["error"], str(exc))
        except FlagsError as exc:
            summary.flags_error += 1
            row["error"] = append_error(row["error"], str(exc))
        except FrameError as exc:
            summary.format_error += 1
            row["error"] = append_error(row["error"], str(exc))
        return row


def append_error(existing: object, new_error: str) -> str:
    return f"{existing};{new_error}" if existing else new_error


def percentile_99(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.99) - 1)]


def summary_lines(summary: PeerSummary) -> list[str]:
    maximum = max(summary.inter_arrivals, default=0.0)
    first = "NONE" if summary.first_sequence is None else str(summary.first_sequence)
    last = "NONE" if summary.last_sequence is None else str(summary.last_sequence)
    result = "PASS" if summary.passed() else "FAIL"
    return [
        "PEER_COMPLETE=1",
        f"RX_TOTAL={summary.rx_total}",
        f"VALID_RX_TOTAL={summary.valid_rx_total}",
        f"FIRST_SEQUENCE={first}",
        f"LAST_SEQUENCE={last}",
        f"EXPECTED_SOURCE_IP={summary.expected_source_ip}",
        f"EXPECTED_SOURCE_PORT={summary.expected_source_port}",
        f"CRC_ERROR={summary.crc_error}",
        f"LENGTH_ERROR={summary.length_error}",
        f"FORMAT_ERROR={summary.format_error}",
        f"PAYLOAD_ERROR={summary.payload_error}",
        f"UNEXPECTED_SOURCE={summary.unexpected_source}",
        f"SEQ_GAP={summary.seq_gap}",
        f"DUPLICATE={summary.duplicate}",
        f"OUT_OF_ORDER={summary.out_of_order}",
        f"FLAGS_ERROR={summary.flags_error}",
        f"SOURCE_PORT_ERROR={summary.source_port_error}",
        f"MAX_INTERARRIVAL_MS={maximum:.6f}",
        f"P99_INTERARRIVAL_MS={percentile_99(summary.inter_arrivals):.6f}",
        f"PEER_RESULT={result}",
    ]


def validate_fixture_stream(
    packets: Iterable[tuple[bytes, tuple[str, int]]],
    expected_source_ip: str = "192.0.2.10",
    expected_source_port: int = DEFAULT_PORT,
    require_first_sequence_zero: bool = True,
) -> tuple[PeerSummary, int]:
    validator = PacketValidator(
        expected_source_ip, expected_source_port, require_first_sequence_zero
    )
    for index, (packet, source) in enumerate(packets):
        validator.observe(packet, source, float(index) * 0.02)
    return validator.summary, 0 if validator.summary.passed() else 2


def run_self_test() -> int:
    parser_results: list[tuple[str, bool, str]] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        parser_results.append((name, condition, detail))

    def expect_error(name: str, packet: bytes, error_type: type[FrameError]) -> None:
        try:
            parse_frame(packet)
        except error_type:
            check(name, True)
        except FrameError as exc:
            check(name, False, f"wrong error {type(exc).__name__}: {exc}")
        else:
            check(name, False, "frame was accepted")

    valid = build_frame(0x12345678, 0x89ABCDEF)
    parsed = parse_frame(valid)
    check("valid_frame", parsed.sequence == 0x12345678)
    expect_error("magic_mismatch", mutate_and_recrc(valid, 0, ord("X")), MagicError)
    expect_error("version_mismatch", mutate_and_recrc(valid, 4, 2), VersionError)
    expect_error("gate_mismatch", mutate_and_recrc(valid, 5, 2), GateError)
    expect_error("length_field_mismatch", mutate_and_recrc(valid, 7, 31), LengthError)
    expect_error("short_packet", valid[:-1], LengthError)
    expect_error("long_packet", valid + b"\x00", LengthError)
    crc_bad = bytearray(valid)
    crc_bad[30] ^= 0x01
    expect_error("crc_mismatch", bytes(crc_bad), CrcError)
    expect_error("payload_mismatch", mutate_and_recrc(valid, 16, valid[16] ^ 1), PayloadError)
    expect_error("flags_mismatch", mutate_and_recrc(valid, 6, 0x01), FlagsError)
    tracker = SequenceTracker()
    tracker.observe(100)
    check("sequence_increment", tracker.observe(101) == SequenceResult())
    wrap_tracker = SequenceTracker()
    wrap_tracker.observe(0xFFFFFFFF)
    check("sequence_wrap", wrap_tracker.observe(0) == SequenceResult())
    duplicate_tracker = SequenceTracker()
    duplicate_tracker.observe(10)
    check("duplicate", duplicate_tracker.observe(10).duplicate)
    order_tracker = SequenceTracker()
    order_tracker.observe(10)
    check("out_of_order", order_tracker.observe(9).out_of_order)
    gap_tracker = SequenceTracker()
    gap_tracker.observe(10)
    check("gap", gap_tracker.observe(14).gap == 3)
    check("timestamp_parse", parsed.device_micros == 0x89ABCDEF)

    source = ("192.0.2.10", DEFAULT_PORT)
    good = [(build_frame(i, i * 20000), source) for i in range(4)]
    bad_crc = bytearray(build_frame(0, 0))
    bad_crc[30] ^= 1
    negative_fixtures: list[tuple[str, list[tuple[bytes, tuple[str, int]]], bool, bool]] = [
        ("valid_stream", good, True, True),
        ("zero_packet", [], True, False),
        ("bad_crc", [(bytes(bad_crc), source)], True, False),
        ("wrong_length", [(build_frame(0, 0)[:-1], source)], True, False),
        ("bad_payload", [(mutate_and_recrc(build_frame(0, 0), 16, 0), source)], True, False),
        ("gap", [(build_frame(0, 0), source), (build_frame(2, 40000), source)], True, False),
        ("duplicate", [(build_frame(0, 0), source), (build_frame(0, 20000), source)], True, False),
        ("out_of_order", [(build_frame(0, 0), source), (build_frame(0xFFFFFFFF, 20000), source)], True, False),
        ("unexpected_source_ip", [(build_frame(0, 0), ("192.0.2.11", DEFAULT_PORT))], True, False),
        ("unexpected_source_port", [(build_frame(0, 0), (source[0], 50002))], True, False),
        ("wrong_flags", [(build_frame(0, 0, 0x01), source)], True, False),
        ("first_sequence_nonzero", [(build_frame(1, 0), source)], True, False),
        (
            "sequence_wrap_valid",
            [
                (build_frame(0xFFFFFFFE, 0), source),
                (build_frame(0xFFFFFFFF, 20000), source),
                (build_frame(0, 40000), source),
            ],
            False,
            True,
        ),
    ]
    negative_ok = True
    for name, packets, require_zero, expected_pass in negative_fixtures:
        summary, exit_code = validate_fixture_stream(
            packets, require_first_sequence_zero=require_zero
        )
        actual_pass = exit_code == 0 and summary.passed()
        fixture_ok = actual_pass == expected_pass and exit_code == (0 if expected_pass else 2)
        negative_ok = negative_ok and fixture_ok
        print(
            f"PEER_NEGATIVE_TEST case={name} result={'PASS' if fixture_ok else 'FAIL'} "
            f"expected_exit={0 if expected_pass else 2} actual_exit={exit_code}"
        )

    for name, passed, detail in parser_results:
        suffix = f" detail={detail}" if detail else ""
        print(f"SELF_TEST case={name} result={'PASS' if passed else 'FAIL'}{suffix}")
    parser_ok = all(result[1] for result in parser_results)
    passed = parser_ok and negative_ok
    print(f"PEER_NEGATIVE_TESTS={'PASS' if negative_ok else 'FAIL'} TESTS={len(negative_fixtures)}")
    print(f"PEER_SELF_TEST={'PASS' if passed else 'FAIL'} TESTS={len(parser_results)}")
    return 0 if passed else 1


def run_tx_sink(args: argparse.Namespace) -> int:
    output_stream: TextIO = sys.stdout
    owned_stream: TextIO | None = None
    if args.output_csv:
        Path(args.output_csv).parent.mkdir(parents=True, exist_ok=True)
        owned_stream = Path(args.output_csv).open("w", newline="", encoding="utf-8")
        output_stream = owned_stream
    fieldnames = [
        "host_timestamp", "source_ip", "source_port", "packet_length",
        "sequence", "device_micros", "crc", "payload", "flags", "duplicate",
        "out_of_order", "gap", "inter_arrival_ms", "error",
    ]
    writer = csv.DictWriter(output_stream, fieldnames=fieldnames)
    writer.writeheader()
    validator = PacketValidator(args.expected_source_ip, args.expected_source_port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.25)
    sock.bind((args.bind_ip, args.port))
    stop_file = Path(args.stop_file) if args.stop_file else None
    if args.ready_file:
        Path(args.ready_file).write_text("PEER_READY=1\n", encoding="utf-8")
    print(
        f"PEER_READY=1 MODE=tx-sink BIND={args.bind_ip}:{args.port} "
        f"DURATION_SECONDS={args.duration_seconds}",
        file=sys.stderr,
        flush=True,
    )
    start = time.monotonic()
    try:
        while time.monotonic() - start < args.duration_seconds:
            if stop_file and stop_file.exists():
                print("PEER_STOP_FILE_OBSERVED=1", file=sys.stderr, flush=True)
                break
            try:
                packet, source = sock.recvfrom(65535)
            except socket.timeout:
                continue
            row = validator.observe(packet, source, time.monotonic())
            writer.writerow(row)
            output_stream.flush()
    finally:
        sock.close()
        if owned_stream:
            owned_stream.close()
    for line in summary_lines(validator.summary):
        print(line, flush=True)
    return 0 if validator.summary.passed() else 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("self-test", "tx-sink"))
    parser.add_argument("--bind-ip")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--duration-seconds", type=float, default=60.0)
    parser.add_argument("--expected-source-ip")
    parser.add_argument("--expected-source-port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--output-csv")
    parser.add_argument("--ready-file")
    parser.add_argument("--stop-file")
    args = parser.parse_args()
    if args.mode == "tx-sink":
        if not args.bind_ip:
            parser.error("tx-sink requires --bind-ip")
        if not args.expected_source_ip:
            parser.error("tx-sink requires --expected-source-ip")
        if args.duration_seconds <= 0:
            parser.error("--duration-seconds must be positive")
        if not 1 <= args.port <= 65535 or not 1 <= args.expected_source_port <= 65535:
            parser.error("ports must be in 1..65535")
    return args


def main() -> int:
    args = parse_args()
    return run_self_test() if args.mode == "self-test" else run_tx_sink(args)


if __name__ == "__main__":
    raise SystemExit(main())
