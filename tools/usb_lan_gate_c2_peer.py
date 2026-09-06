#!/usr/bin/env python3
"""Gate C2 UDP echo peer with three-state admission and offline fixtures.

This is a new, additive file for Gate C2 (Mode 16, USB_FIXED10_UDP_ECHO). It
does not import or modify tools/usb_lan_gate_peer.py (the Gate C1 peer); the
C2UD frame parser below is a deliberate, independent duplicate of the C1UD
parser, adapted for gate id 2, so that C1's accepted peer source is never
touched. See docs/usb-lan-gate-c2-contract.md for the canonical requirements
this file implements (three-state peer admission, exactly-once echo,
BOUND_NOT_ARMED suppression, BLOCKED_ADMISSION_SEQUENCE_MISS).
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import enum
import math
import os
import socket
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Optional, TextIO

FRAME_LENGTH = 32
MAGIC = b"C2UD"
VERSION = 1
GATE_ID = 2
DEFAULT_PORT = 50001
FLAG_HORI_READY = 0x01
FLAG_FIXED10HALF_LINK = 0x02
REQUIRED_FLAGS = FLAG_HORI_READY | FLAG_FIXED10HALF_LINK
FORBIDDEN_FLAGS = 0x00
RESERVED_FLAGS = 0xFC

PRECONDITION_ARM_STATE_INVALID = "PRECONDITION_ARM_STATE_INVALID"
BLOCKED_ADMISSION_SEQUENCE_MISS = "BLOCKED_ADMISSION_SEQUENCE_MISS"

EXIT_PASS = 0
EXIT_FAIL = 2
EXIT_BLOCKED_ADMISSION = 3


class FrameError(ValueError):
    """Base class for rejected Gate C2 frames."""


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


def append_error(existing: object, new_error: str) -> str:
    return f"{existing};{new_error}" if existing else new_error


@dataclass
class BaseSummary:
    expected_source_ip: str
    expected_source_port: int
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


class PacketValidator:
    """Parses/validates C2UD frames and tracks sequence integrity.

    Deliberately parallel to the Gate C1 peer's PacketValidator (same
    field semantics), but never sequence-zero-gates admission itself --
    that policy lives one layer up in C2AdmissionController, since C2 adds
    an operator-driven arm/admission handshake that C1 does not have.
    """

    def __init__(self, expected_source_ip: str, expected_source_port: int) -> None:
        self.summary = BaseSummary(expected_source_ip, expected_source_port)
        self.tracker = SequenceTracker()
        self.previous_arrival: float | None = None

    def observe(self, packet: bytes, source: tuple[str, int], arrival: float) -> dict[str, object]:
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


class AdmissionState(enum.Enum):
    BOUND_NOT_ARMED = "BOUND_NOT_ARMED"
    ARMED_WAIT_SEQUENCE_ZERO = "ARMED_WAIT_SEQUENCE_ZERO"
    ADMITTED = "ADMITTED"


EchoSender = Callable[[bytes, tuple[str, int]], bool]


class C2AdmissionController:
    """Implements the canonical three-state peer admission machine.

    BOUND_NOT_ARMED: every packet is logged only; no echo, no counting.
    ARMED_WAIT_SEQUENCE_ZERO: the first fully-valid frame decides admission.
      sequence == 0 -> ADMITTED. sequence != 0 -> BLOCKED_ADMISSION_SEQUENCE_MISS
      (a distinct classification, not a C2 network FAIL; no automatic retry).
    ADMITTED: strict per-packet validation, exactly-once echo per new
      sequence (never re-sent for a sequence already echoed).
    """

    def __init__(
        self,
        validator: PacketValidator,
        send_echo: EchoSender,
    ) -> None:
        self.state = AdmissionState.BOUND_NOT_ARMED
        self.validator = validator
        self._send_echo = send_echo
        self._echoed_sequences: set[int] = set()
        self.peer_armed = False
        self.admission_sequence_zero_ok = False
        self.blocked_admission_sequence_miss = False
        self.echo_sent_total = 0
        self.echo_send_failures = 0
        self.unsolicited_echo_sent = 0
        self.valid_rx_total_post_admission = 0
        # BOUND_NOT_ARMED_PACKET_COUNT: every packet observed before arming.
        self.bound_not_armed_packet_count = 0
        # PRE_ADMISSION_NON_C2_COUNT: packets observed while
        # ARMED_WAIT_SEQUENCE_ZERO that are not a fully-valid C2 frame from
        # the expected source (e.g. leftover old-protocol traffic, garbage,
        # or a frame that fails structural/source validation). These never
        # touch the strict PacketValidator counters that gate the final
        # Peer PASS contract.
        self.pre_admission_non_c2_count = 0

    def arm(self) -> None:
        if self.state is AdmissionState.BOUND_NOT_ARMED:
            self.state = AdmissionState.ARMED_WAIT_SEQUENCE_ZERO
            self.peer_armed = True

    def _dispatch_echo(self, packet: bytes, source: tuple[str, int]) -> bool:
        # The only call site that may send an echo. Guarded independently of
        # the caller so an accidental call outside ADMITTED is caught and
        # counted rather than silently sending an unsolicited packet.
        if self.state is not AdmissionState.ADMITTED:
            self.unsolicited_echo_sent += 1
            return False
        try:
            return self._send_echo(packet, source)
        except OSError:
            return False

    def _try_fully_valid_c2(self, packet: bytes, source: tuple[str, int]) -> Frame | None:
        # Pure, non-mutating check: does NOT touch validator/tracker state,
        # so a non-C2 or wrong-source packet observed pre-admission never
        # poisons the strict counters (PRE_ADMISSION_NON_C2_COUNT tracks it
        # separately instead).
        summary = self.validator.summary
        if source[0] != summary.expected_source_ip:
            return None
        if source[1] != summary.expected_source_port:
            return None
        try:
            return parse_frame(packet)
        except FrameError:
            return None

    def _process_admitted_packet(
        self, packet: bytes, source: tuple[str, int], arrival: float
    ) -> dict[str, object]:
        row = self.validator.observe(packet, source, arrival)
        row["state"] = AdmissionState.ADMITTED.value
        row["echoed"] = 0
        fully_valid = row["sequence"] != "" and row["error"] == ""
        if not fully_valid:
            return row

        sequence = row["sequence"]
        assert isinstance(sequence, int)
        if sequence in self._echoed_sequences:
            # Already echoed once for this sequence: no retransmission.
            return row

        self.valid_rx_total_post_admission += 1
        success = self._dispatch_echo(packet, source)
        if success:
            self._echoed_sequences.add(sequence)
            self.echo_sent_total += 1
            row["echoed"] = 1
        else:
            self.echo_send_failures += 1
        return row

    def observe(self, packet: bytes, source: tuple[str, int], arrival: float) -> dict[str, object]:
        if self.state is AdmissionState.BOUND_NOT_ARMED:
            self.bound_not_armed_packet_count += 1
            return {
                "state": AdmissionState.BOUND_NOT_ARMED.value,
                "source_ip": source[0],
                "source_port": source[1],
                "packet_length": len(packet),
                "sequence": "",
                "echoed": 0,
                "error": "",
            }
        if self.blocked_admission_sequence_miss:
            return {
                "state": BLOCKED_ADMISSION_SEQUENCE_MISS,
                "source_ip": source[0],
                "source_port": source[1],
                "packet_length": len(packet),
                "sequence": "",
                "echoed": 0,
                "error": "trial_blocked",
            }

        if self.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO:
            frame = self._try_fully_valid_c2(packet, source)
            if frame is None:
                self.pre_admission_non_c2_count += 1
                return {
                    "state": AdmissionState.ARMED_WAIT_SEQUENCE_ZERO.value,
                    "source_ip": source[0],
                    "source_port": source[1],
                    "packet_length": len(packet),
                    "sequence": "",
                    "echoed": 0,
                    "error": "pre_admission_non_c2",
                }
            if frame.sequence != 0:
                self.blocked_admission_sequence_miss = True
                return {
                    "state": BLOCKED_ADMISSION_SEQUENCE_MISS,
                    "source_ip": source[0],
                    "source_port": source[1],
                    "packet_length": len(packet),
                    "sequence": frame.sequence,
                    "echoed": 0,
                    "error": BLOCKED_ADMISSION_SEQUENCE_MISS,
                }
            # Fully valid C2 frame, sequence 0: admit, then count/echo it
            # through the normal ADMITTED-state path (first tracked packet).
            self.state = AdmissionState.ADMITTED
            self.admission_sequence_zero_ok = True
            return self._process_admitted_packet(packet, source, arrival)

        return self._process_admitted_packet(packet, source, arrival)

    def passed(self) -> bool:
        summary = self.validator.summary
        return (
            not self.blocked_admission_sequence_miss
            and self.peer_armed
            and self.admission_sequence_zero_ok
            and summary.rx_total > 0
            and summary.valid_rx_total > 0
            and summary.crc_error == 0
            and summary.length_error == 0
            and summary.format_error == 0
            and summary.payload_error == 0
            and summary.unexpected_source == 0
            and summary.seq_gap == 0
            and summary.duplicate == 0
            and summary.out_of_order == 0
            and summary.flags_error == 0
            and summary.source_port_error == 0
            and self.echo_send_failures == 0
            and self.unsolicited_echo_sent == 0
            and self.echo_sent_total == self.valid_rx_total_post_admission
        )


def percentile_99(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.99) - 1)]


def summary_lines(controller: C2AdmissionController) -> list[str]:
    summary = controller.validator.summary
    maximum = max(summary.inter_arrivals, default=0.0)
    first = "NONE" if summary.first_sequence is None else str(summary.first_sequence)
    last = "NONE" if summary.last_sequence is None else str(summary.last_sequence)
    if controller.blocked_admission_sequence_miss:
        result = BLOCKED_ADMISSION_SEQUENCE_MISS
    else:
        result = "PASS" if controller.passed() else "FAIL"
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
        f"PEER_ARMED={int(controller.peer_armed)}",
        f"ADMISSION_SEQUENCE_ZERO_OK={int(controller.admission_sequence_zero_ok)}",
        f"BLOCKED_ADMISSION_SEQUENCE_MISS={int(controller.blocked_admission_sequence_miss)}",
        f"BOUND_NOT_ARMED_PACKET_COUNT={controller.bound_not_armed_packet_count}",
        f"PRE_ADMISSION_NON_C2_COUNT={controller.pre_admission_non_c2_count}",
        f"ECHO_SENT_TOTAL={controller.echo_sent_total}",
        f"ECHO_SEND_FAILURES={controller.echo_send_failures}",
        f"UNSOLICITED_ECHO_SENT={controller.unsolicited_echo_sent}",
        f"VALID_RX_TOTAL_POST_ADMISSION={controller.valid_rx_total_post_admission}",
        f"MAX_INTERARRIVAL_MS={maximum:.6f}",
        f"P99_INTERARRIVAL_MS={percentile_99(summary.inter_arrivals):.6f}",
        f"PEER_RESULT={result}",
    ]


def check_arm_preconditions(arm_file: Path, armed_file: Path) -> Optional[str]:
    """Pure filesystem check: neither IPC file may exist at peer start."""
    if arm_file.exists() or armed_file.exists():
        return PRECONDITION_ARM_STATE_INVALID
    return None


def write_armed_file(armed_file: Path) -> None:
    """Atomically create the armed-file acknowledgement.

    Writes to a temporary file in the same directory, then uses os.replace
    so the runner never observes a partially written armed-file.
    """
    armed_file.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{armed_file.name}.", dir=str(armed_file.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("PEER_ARMED=1\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, armed_file)
    finally:
        if os.path.exists(temp_name):
            os.remove(temp_name)


class FakeEchoChannel:
    """Offline stand-in for a UDP socket's sendto(), used by self-tests."""

    def __init__(self, fail_on: set[int] | None = None) -> None:
        self.sent: list[tuple[bytes, tuple[str, int]]] = []
        self.fail_on = fail_on or set()
        self.call_count = 0

    def __call__(self, packet: bytes, source: tuple[str, int]) -> bool:
        index = self.call_count
        self.call_count += 1
        if index in self.fail_on:
            return False
        self.sent.append((packet, source))
        return True


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

    # --- Frame-level parser fixtures (magic/version/gate/length/flags/CRC/payload) ---
    valid = build_frame(0x12345678, 0x89ABCDEF)
    parsed = parse_frame(valid)
    check("valid_frame", parsed.sequence == 0x12345678)
    expect_error("magic_error", mutate_and_recrc(valid, 0, ord("X")), MagicError)
    expect_error("version_error", mutate_and_recrc(valid, 4, 2), VersionError)
    expect_error("gate_error", mutate_and_recrc(valid, 5, 1), GateError)
    expect_error("length_error_field", mutate_and_recrc(valid, 7, 31), LengthError)
    expect_error("length_error_short", valid[:-1], LengthError)
    expect_error("length_error_long", valid + b"\x00", LengthError)
    crc_bad = bytearray(valid)
    crc_bad[30] ^= 0x01
    expect_error("crc_error", bytes(crc_bad), CrcError)
    expect_error("payload_error", mutate_and_recrc(valid, 16, valid[16] ^ 1), PayloadError)
    expect_error("flags_error", mutate_and_recrc(valid, 6, 0x01), FlagsError)
    check("timestamp_parse", parsed.device_micros == 0x89ABCDEF)

    # --- wrong source / wrong source port (PacketValidator, pre-admission-agnostic) ---
    expected_source = ("192.0.2.10", DEFAULT_PORT)
    wrong_ip_validator = PacketValidator(*expected_source)
    wrong_ip_row = wrong_ip_validator.observe(build_frame(0, 0), ("192.0.2.11", DEFAULT_PORT), 0.0)
    check("wrong_source_ip", wrong_ip_validator.summary.unexpected_source == 1 and wrong_ip_row["error"] != "")
    wrong_port_validator = PacketValidator(*expected_source)
    wrong_port_row = wrong_port_validator.observe(build_frame(0, 0), (expected_source[0], 50002), 0.0)
    check("wrong_source_port", wrong_port_validator.summary.source_port_error == 1 and wrong_port_row["error"] != "")

    # --- BOUND_NOT_ARMED suppression ---
    channel = FakeEchoChannel()
    validator = PacketValidator(*expected_source)
    controller = C2AdmissionController(validator, channel)
    for sequence in range(3):
        row = controller.observe(build_frame(sequence, sequence * 20000), expected_source, sequence * 0.02)
        check(
            f"bound_not_armed_suppressed[{sequence}]",
            row["state"] == "BOUND_NOT_ARMED" and row["echoed"] == 0,
        )
    check("bound_not_armed_packet_count", controller.bound_not_armed_packet_count == 3)
    check("bound_not_armed_no_rx_counted", validator.summary.rx_total == 0)
    check("bound_not_armed_no_echo", len(channel.sent) == 0)
    # BOUND_NOT_ARMED must never poison any strict counter, including on a
    # malformed/garbage packet observed before arming.
    garbage = b"\x00" * FRAME_LENGTH
    controller.observe(garbage, expected_source, 0.06)
    check(
        "bound_not_armed_never_poisons_strict_counters",
        controller.bound_not_armed_packet_count == 4
        and validator.summary.rx_total == 0
        and validator.summary.format_error == 0
        and validator.summary.crc_error == 0,
    )

    # --- arm detection / armed acknowledgement (pure filesystem + state machine) ---
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        arm_file = tmp_path / "arm"
        armed_file = tmp_path / "armed"
        check("arm_precondition_clean", check_arm_preconditions(arm_file, armed_file) is None)
        arm_file.write_text("ARM=1", encoding="utf-8")
        check(
            "arm_precondition_rejects_preexisting_arm_file",
            check_arm_preconditions(arm_file, armed_file) == PRECONDITION_ARM_STATE_INVALID,
        )
        arm_file.unlink()
        armed_file.write_text("PEER_ARMED=1", encoding="utf-8")
        check(
            "arm_precondition_rejects_preexisting_armed_file",
            check_arm_preconditions(arm_file, armed_file) == PRECONDITION_ARM_STATE_INVALID,
        )
        armed_file.unlink()
        write_armed_file(armed_file)
        check("armed_file_written_atomically", armed_file.read_text(encoding="utf-8") == "PEER_ARMED=1\n")
        leftover_temp_files = list(tmp_path.glob(f".{armed_file.name}.*"))
        check("armed_file_no_leftover_temp", len(leftover_temp_files) == 0)

    arm_channel = FakeEchoChannel()
    arm_validator = PacketValidator(*expected_source)
    arm_controller = C2AdmissionController(arm_validator, arm_channel)
    check("initial_state_bound_not_armed", arm_controller.state is AdmissionState.BOUND_NOT_ARMED)
    arm_controller.arm()
    check("arm_transitions_state", arm_controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO)
    check("arm_sets_peer_armed", arm_controller.peer_armed)
    arm_controller.arm()
    check(
        "arm_is_idempotent",
        arm_controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO,
    )

    # --- admission sequence 0 ---
    seq0_channel = FakeEchoChannel()
    seq0_validator = PacketValidator(*expected_source)
    seq0_controller = C2AdmissionController(seq0_validator, seq0_channel)
    seq0_controller.arm()
    seq0_row = seq0_controller.observe(build_frame(0, 0), expected_source, 0.0)
    check("admission_sequence_zero_admits", seq0_controller.state is AdmissionState.ADMITTED)
    check("admission_sequence_zero_flag", seq0_controller.admission_sequence_zero_ok)
    check("admission_sequence_zero_echoed", seq0_row["echoed"] == 1 and len(seq0_channel.sent) == 1)
    check("admission_sequence_zero_not_blocked", not seq0_controller.blocked_admission_sequence_miss)

    # --- admission nonzero block ---
    blocked_channel = FakeEchoChannel()
    blocked_validator = PacketValidator(*expected_source)
    blocked_controller = C2AdmissionController(blocked_validator, blocked_channel)
    blocked_controller.arm()
    blocked_row = blocked_controller.observe(build_frame(5, 0), expected_source, 0.0)
    check(
        "admission_nonzero_blocks",
        blocked_controller.blocked_admission_sequence_miss
        and blocked_row["state"] == BLOCKED_ADMISSION_SEQUENCE_MISS,
    )
    check("admission_nonzero_not_admitted", blocked_controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO)
    check("admission_nonzero_no_echo", len(blocked_channel.sent) == 0 and blocked_row["echoed"] == 0)
    check(
        "admission_nonzero_not_classified_as_fail",
        summary_lines(blocked_controller)[-1] == f"PEER_RESULT={BLOCKED_ADMISSION_SEQUENCE_MISS}",
    )
    # Further packets after blocked must remain log-only (no automatic retry).
    followup_row = blocked_controller.observe(build_frame(0, 20000), expected_source, 0.02)
    check(
        "admission_nonzero_blocked_stays_blocked",
        followup_row["state"] == BLOCKED_ADMISSION_SEQUENCE_MISS and followup_row["echoed"] == 0,
    )
    check("admission_nonzero_blocked_no_extra_echo", len(blocked_channel.sent) == 0)
    check("admission_nonzero_no_pre_admission_non_c2", blocked_controller.pre_admission_non_c2_count == 0)

    # --- ARMED_WAIT: old C1 / non-C2 traffic is log-only, never poisons strict counters ---
    old_c1_frame = bytearray(build_frame(0, 0))
    old_c1_frame[0:4] = b"C1UD"
    old_c1_frame[30:32] = crc16_ccitt_false(bytes(old_c1_frame[:30])).to_bytes(2, "big")
    old_c1_frame = bytes(old_c1_frame)

    nonc2_channel = FakeEchoChannel()
    nonc2_validator = PacketValidator(*expected_source)
    nonc2_controller = C2AdmissionController(nonc2_validator, nonc2_channel)
    nonc2_controller.arm()
    old_row = nonc2_controller.observe(old_c1_frame, expected_source, 0.0)
    check(
        "armed_wait_old_c1_packet_log_only",
        old_row["state"] == "ARMED_WAIT_SEQUENCE_ZERO" and old_row["echoed"] == 0,
    )
    check("armed_wait_old_c1_pre_admission_non_c2_count", nonc2_controller.pre_admission_non_c2_count == 1)
    check(
        "armed_wait_old_c1_never_poisons_strict_counters",
        nonc2_validator.summary.rx_total == 0
        and nonc2_validator.summary.format_error == 0
        and nonc2_controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO,
    )
    check("armed_wait_old_c1_no_echo", len(nonc2_channel.sent) == 0)

    # Garbage (not even a well-formed frame) during ARMED_WAIT is likewise
    # log-only via PRE_ADMISSION_NON_C2_COUNT, never a strict-counter error.
    garbage_row = nonc2_controller.observe(b"\x01" * FRAME_LENGTH, expected_source, 0.01)
    check(
        "armed_wait_garbage_pre_admission_non_c2",
        garbage_row["state"] == "ARMED_WAIT_SEQUENCE_ZERO"
        and nonc2_controller.pre_admission_non_c2_count == 2
        and nonc2_validator.summary.rx_total == 0,
    )

    # --- old traffic then sequence 0 admission succeeds -> final Peer PASS possible ---
    recovery_channel = FakeEchoChannel()
    recovery_validator = PacketValidator(*expected_source)
    recovery_controller = C2AdmissionController(recovery_validator, recovery_channel)
    recovery_controller.arm()
    recovery_controller.observe(old_c1_frame, expected_source, 0.0)
    recovery_controller.observe(b"\x02" * FRAME_LENGTH, expected_source, 0.01)
    check(
        "recovery_pre_admission_traffic_did_not_admit",
        recovery_controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO
        and recovery_controller.pre_admission_non_c2_count == 2,
    )
    fresh_seq0_row = recovery_controller.observe(build_frame(0, 100000), expected_source, 0.02)
    check(
        "recovery_fresh_sequence_zero_admits",
        recovery_controller.state is AdmissionState.ADMITTED
        and recovery_controller.admission_sequence_zero_ok
        and fresh_seq0_row["echoed"] == 1,
    )
    for sequence in range(1, 5):
        recovery_controller.observe(build_frame(sequence, 100000 + sequence * 20000), expected_source, 0.02 + sequence * 0.02)
    check(
        "recovery_final_peer_pass_possible",
        recovery_controller.passed()
        and not recovery_controller.blocked_admission_sequence_miss
        and recovery_controller.pre_admission_non_c2_count == 2
        and recovery_validator.summary.rx_total == 5,
    )

    # --- strict post-admission (CRC-corrupted frame after admission is rejected, not echoed) ---
    strict_channel = FakeEchoChannel()
    strict_validator = PacketValidator(*expected_source)
    strict_controller = C2AdmissionController(strict_validator, strict_channel)
    strict_controller.arm()
    strict_controller.observe(build_frame(0, 0), expected_source, 0.0)
    corrupted = bytearray(build_frame(1, 20000))
    corrupted[30] ^= 0x01
    corrupted_row = strict_controller.observe(bytes(corrupted), expected_source, 0.02)
    check(
        "strict_post_admission_rejects_crc_error",
        strict_validator.summary.crc_error == 1 and corrupted_row["echoed"] == 0,
    )
    check("strict_post_admission_no_echo_on_error", len(strict_channel.sent) == 1)

    # --- duplicate / out-of-order / gap (post-admission sequencing) ---
    seq_channel = FakeEchoChannel()
    seq_validator = PacketValidator(*expected_source)
    seq_controller = C2AdmissionController(seq_validator, seq_channel)
    seq_controller.arm()
    seq_controller.observe(build_frame(0, 0), expected_source, 0.0)
    seq_controller.observe(build_frame(1, 20000), expected_source, 0.02)
    dup_row = seq_controller.observe(build_frame(1, 40000), expected_source, 0.04)
    check("duplicate_detected", seq_validator.summary.duplicate == 1)
    check("duplicate_not_reechoed", dup_row["echoed"] == 0)
    gap_row = seq_controller.observe(build_frame(4, 60000), expected_source, 0.06)
    check("gap_detected", gap_row["gap"] == 2 and seq_validator.summary.seq_gap == 2)
    ooo_row = seq_controller.observe(build_frame(0, 80000), expected_source, 0.08)
    check("out_of_order_detected", ooo_row["out_of_order"] == 1)

    # --- exactly-once echo contract ---
    exactly_once_channel = FakeEchoChannel()
    exactly_once_validator = PacketValidator(*expected_source)
    exactly_once_controller = C2AdmissionController(exactly_once_validator, exactly_once_channel)
    exactly_once_controller.arm()
    frame0 = build_frame(0, 0)
    first_row = exactly_once_controller.observe(frame0, expected_source, 0.0)
    second_row = exactly_once_controller.observe(frame0, expected_source, 0.02)
    check(
        "exactly_once_first_send_echoes",
        first_row["echoed"] == 1 and exactly_once_controller.echo_sent_total == 1,
    )
    check(
        "exactly_once_retransmit_not_reechoed",
        second_row["echoed"] == 0 and exactly_once_controller.echo_sent_total == 1,
    )
    check("exactly_once_channel_saw_one_send", len(exactly_once_channel.sent) == 1)
    check(
        "exactly_once_invariant_echo_equals_valid_post_admission",
        exactly_once_controller.echo_sent_total == exactly_once_controller.valid_rx_total_post_admission,
    )

    # --- unsolicited echo guard (defensive dispatch path, exercised directly) ---
    unsolicited_channel = FakeEchoChannel()
    unsolicited_validator = PacketValidator(*expected_source)
    unsolicited_controller = C2AdmissionController(unsolicited_validator, unsolicited_channel)
    # Controller is still BOUND_NOT_ARMED: a direct dispatch attempt must be
    # refused and counted, proving the guard independent of observe()'s
    # normal control flow.
    dispatch_ok = unsolicited_controller._dispatch_echo(build_frame(0, 0), expected_source)
    check(
        "unsolicited_echo_guard_refuses",
        not dispatch_ok and unsolicited_controller.unsolicited_echo_sent == 1,
    )
    check("unsolicited_echo_guard_no_send", len(unsolicited_channel.sent) == 0)

    # --- echo send failure classification ---
    failing_channel = FakeEchoChannel(fail_on={0})
    failing_validator = PacketValidator(*expected_source)
    failing_controller = C2AdmissionController(failing_validator, failing_channel)
    failing_controller.arm()
    failing_row = failing_controller.observe(build_frame(0, 0), expected_source, 0.0)
    check(
        "echo_send_failure_counted",
        failing_row["echoed"] == 0 and failing_controller.echo_send_failures == 1,
    )
    check("echo_send_failure_fails_peer", not failing_controller.passed())

    for name, passed, detail in parser_results:
        suffix = f" detail={detail}" if detail else ""
        print(f"SELF_TEST case={name} result={'PASS' if passed else 'FAIL'}{suffix}")
    parser_ok = all(result[1] for result in parser_results)
    print(f"PEER_SELF_TEST={'PASS' if parser_ok else 'FAIL'} TESTS={len(parser_results)}")
    return 0 if parser_ok else 1


def run_echo(args: argparse.Namespace) -> int:
    """Live networked echo mode.

    Not exercised by this implementation task (network bind/UDP traffic is
    out of scope); provided so the C2 runner has a real target to invoke
    during a future authorized physical trial.
    """
    arm_file = Path(args.arm_file)
    armed_file = Path(args.armed_file)
    precondition_error = check_arm_preconditions(arm_file, armed_file)
    if precondition_error:
        print(f"PEER_RESULT=FAIL REASON={precondition_error}", flush=True)
        return EXIT_FAIL

    output_stream: TextIO = sys.stdout
    owned_stream: TextIO | None = None
    if args.csv:
        Path(args.csv).parent.mkdir(parents=True, exist_ok=True)
        owned_stream = Path(args.csv).open("w", newline="", encoding="utf-8")
        output_stream = owned_stream
    fieldnames = [
        "host_timestamp", "state", "source_ip", "source_port", "packet_length",
        "sequence", "device_micros", "crc", "payload", "flags", "duplicate",
        "out_of_order", "gap", "inter_arrival_ms", "echoed", "error",
    ]
    writer = csv.DictWriter(output_stream, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()

    validator = PacketValidator(args.expected_source_ip, args.expected_source_port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.25)
    sock.bind((args.bind_ip, args.port))

    def send_echo(packet: bytes, source: tuple[str, int]) -> bool:
        try:
            sock.sendto(packet, source)
            return True
        except OSError:
            return False

    controller = C2AdmissionController(validator, send_echo)
    stop_file = Path(args.stop_file) if args.stop_file else None
    if args.ready_file:
        Path(args.ready_file).write_text("PEER_READY=1\n", encoding="utf-8")
    print(
        f"PEER_READY=1 MODE=echo BIND={args.bind_ip}:{args.port} STATE=BOUND_NOT_ARMED",
        file=sys.stderr,
        flush=True,
    )
    try:
        while True:
            if stop_file and stop_file.exists():
                print("PEER_STOP_FILE_OBSERVED=1", file=sys.stderr, flush=True)
                break
            if controller.state is AdmissionState.BOUND_NOT_ARMED and arm_file.exists():
                controller.arm()
                write_armed_file(armed_file)
                print("PEER_ARMED=1", file=sys.stderr, flush=True)
            try:
                packet, source = sock.recvfrom(65535)
            except socket.timeout:
                continue
            row = controller.observe(packet, source, time.monotonic())
            writer.writerow(row)
            output_stream.flush()
            if controller.blocked_admission_sequence_miss:
                break
    finally:
        sock.close()
        if owned_stream:
            owned_stream.close()
    for line in summary_lines(controller):
        print(line, flush=True)
    if controller.blocked_admission_sequence_miss:
        return EXIT_BLOCKED_ADMISSION
    return EXIT_PASS if controller.passed() else EXIT_FAIL


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("self-test", "echo"))
    parser.add_argument("--bind-ip")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--expected-source-ip")
    parser.add_argument("--expected-source-port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--arm-file")
    parser.add_argument("--armed-file")
    parser.add_argument("--stop-file")
    parser.add_argument("--ready-file")
    parser.add_argument("--csv")
    args = parser.parse_args()
    if args.mode == "echo":
        if not args.bind_ip:
            parser.error("echo mode requires --bind-ip")
        if not args.expected_source_ip:
            parser.error("echo mode requires --expected-source-ip")
        if not args.arm_file or not args.armed_file:
            parser.error("echo mode requires --arm-file and --armed-file")
        if not 1 <= args.port <= 65535 or not 1 <= args.expected_source_port <= 65535:
            parser.error("ports must be in 1..65535")
    return args


def main() -> int:
    args = parse_args()
    return run_self_test() if args.mode == "self-test" else run_echo(args)


if __name__ == "__main__":
    raise SystemExit(main())
