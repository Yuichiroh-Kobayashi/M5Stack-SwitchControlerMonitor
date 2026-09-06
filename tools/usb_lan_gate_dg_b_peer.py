#!/usr/bin/env python3
"""DG-B UNMATCHED_PORT_INGRESS peer and pure offline fixtures.

The live mode is a future physical path.  It is never entered by --self-test.
No SIO_UDP_CONNRESET policy is changed: Windows UDP/ICMP errors are preserved.
"""

from __future__ import annotations

import argparse
import csv
import enum
import json
import math
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, TextIO

FRAME_LENGTH = 32
MAGIC = b"C1UD"
VERSION = 1
GATE_ID = 1
REQUIRED_FLAGS = 0x03
RESERVED_FLAGS = 0xFC

EXPECTED_SOURCE = ("192.168.50.10", 50001)
REQUIRED_BIND = ("192.168.50.30", 50001)
INGRESS_DESTINATION = ("192.168.50.10", 50002)

BLOCKED_ADMISSION_SEQUENCE_MISS = "BLOCKED_ADMISSION_SEQUENCE_MISS"
BLOCKED_EVIDENCE = "BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID"
BLOCKED_ASYNC = "BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR"
SEND_FAIL = "DG_B_PEER_INGRESS_SEND_FAIL"

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_BLOCKED_ADMISSION = 2
EXIT_BLOCKED_CONTROL = 3


class FrameError(ValueError):
    pass


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

    @property
    def valid(self) -> bool:
        return not self.duplicate and not self.out_of_order and self.gap == 0


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


def build_frame(sequence: int, device_micros: int = 0, flags: int = REQUIRED_FLAGS) -> bytes:
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


def mutate_and_recrc(frame: bytes, offset: int, value: int) -> bytes:
    changed = bytearray(frame)
    changed[offset] = value
    changed[30:32] = crc16_ccitt_false(changed[:30]).to_bytes(2, "big")
    return bytes(changed)


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
    flags = packet[6]
    if flags & REQUIRED_FLAGS != REQUIRED_FLAGS or flags & RESERVED_FLAGS:
        raise FlagsError(f"flags {flags:02X} invalid")
    sequence = int.from_bytes(packet[8:12], "big")
    payload = packet[16:30]
    if payload != expected_payload(sequence):
        raise PayloadError("payload mismatch")
    return Frame(flags, sequence, int.from_bytes(packet[12:16], "big"), payload, actual_crc)


@dataclass
class StrictCounters:
    rx_total: int = 0
    valid_total: int = 0
    crc_error: int = 0
    length_error: int = 0
    format_error: int = 0
    payload_error: int = 0
    flags_error: int = 0
    unexpected_source: int = 0
    source_port_error: int = 0
    seq_gap: int = 0
    duplicate: int = 0
    out_of_order: int = 0
    first_sequence: int | None = None
    last_sequence: int | None = None

    def errors_zero(self) -> bool:
        return all(
            value == 0
            for value in (
                self.crc_error,
                self.length_error,
                self.format_error,
                self.payload_error,
                self.flags_error,
                self.unexpected_source,
                self.source_port_error,
                self.seq_gap,
                self.duplicate,
                self.out_of_order,
            )
        )


class StrictValidator:
    def __init__(self, expected_source: tuple[str, int] = EXPECTED_SOURCE) -> None:
        self.expected_source = expected_source
        self.counters = StrictCounters()
        self.tracker = SequenceTracker()

    def pure_candidate(self, packet: bytes, source: tuple[str, int]) -> Frame | None:
        if source != self.expected_source:
            return None
        try:
            return parse_frame(packet)
        except FrameError:
            return None

    def observe(self, packet: bytes, source: tuple[str, int]) -> tuple[Frame | None, str]:
        c = self.counters
        c.rx_total += 1
        errors: list[str] = []
        if source[0] != self.expected_source[0]:
            c.unexpected_source += 1
            errors.append("unexpected_source")
        if source[1] != self.expected_source[1]:
            c.source_port_error += 1
            errors.append("source_port_error")
        try:
            frame = parse_frame(packet)
        except LengthError as exc:
            c.length_error += 1
            return None, ";".join(errors + [str(exc)])
        except CrcError as exc:
            c.crc_error += 1
            return None, ";".join(errors + [str(exc)])
        except PayloadError as exc:
            c.payload_error += 1
            return None, ";".join(errors + [str(exc)])
        except FlagsError as exc:
            c.flags_error += 1
            return None, ";".join(errors + [str(exc)])
        except FrameError as exc:
            c.format_error += 1
            return None, ";".join(errors + [str(exc)])

        sequence = self.tracker.observe(frame.sequence)
        c.duplicate += int(sequence.duplicate)
        c.out_of_order += int(sequence.out_of_order)
        c.seq_gap += sequence.gap
        if sequence.duplicate:
            errors.append("duplicate")
        if sequence.out_of_order:
            errors.append("out_of_order")
        if sequence.gap:
            errors.append(f"gap_{sequence.gap}")
        if c.first_sequence is None:
            c.first_sequence = frame.sequence
        c.last_sequence = frame.sequence
        if not errors:
            c.valid_total += 1
            return frame, ""
        return None, ";".join(errors)


class AdmissionState(enum.Enum):
    BOUND_NOT_ARMED = "BOUND_NOT_ARMED"
    ARMED_WAIT_SEQUENCE_ZERO = "ARMED_WAIT_SEQUENCE_ZERO"
    ADMITTED = "ADMITTED"


@dataclass
class SocketErrorEvidence:
    phase: str
    sequence: int | None
    errno: int | None
    winerror: int | None
    message: str

    @staticmethod
    def from_exception(phase: str, sequence: int | None, exc: BaseException) -> "SocketErrorEvidence":
        return SocketErrorEvidence(
            phase=phase if phase in {"BIND", "GETSOCKNAME", "RECVFROM", "SENDTO"} else "NONE",
            sequence=sequence,
            errno=getattr(exc, "errno", None),
            winerror=getattr(exc, "winerror", None),
            message=str(exc),
        )


@dataclass
class TimingEvidence:
    sequence: int
    rx_ns: int
    send_attempt_ns: int
    send_result_ns: int
    result: str

    @property
    def valid(self) -> bool:
        return self.rx_ns <= self.send_attempt_ns <= self.send_result_ns

    @property
    def rx_to_send_us(self) -> float:
        return (self.send_attempt_ns - self.rx_ns) / 1000.0

    @property
    def send_call_us(self) -> float:
        return (self.send_result_ns - self.send_attempt_ns) / 1000.0


def percentile_99(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.99 * len(ordered)) - 1)]


SendTo = Callable[[bytes, tuple[str, int]], int]


@dataclass
class PeerEvidence:
    bound_ip: str = "NA"
    bound_port: int | None = None
    peer_complete: bool = False
    peer_armed: bool = False
    admission_sequence_zero_ok: bool = False
    blocked_admission_sequence_miss: bool = False
    bound_not_armed_packet_count: int = 0
    pre_admission_non_c1_count: int = 0
    ingress_attempt_total: int = 0
    ingress_success_total: int = 0
    ingress_fail_total: int = 0
    ingress_first_sequence: int | None = None
    ingress_last_sequence: int | None = None
    unsolicited_send_total: int = 0
    socket_errors: list[SocketErrorEvidence] = field(default_factory=list)
    timings: list[TimingEvidence] = field(default_factory=list)
    timing_evidence_valid: bool = True
    fatal_reason: str | None = None


class DgBController:
    def __init__(self, sendto: SendTo, bound_identity: tuple[str, int]) -> None:
        self.state = AdmissionState.BOUND_NOT_ARMED
        self.validator = StrictValidator()
        self.sendto = sendto
        self.evidence = PeerEvidence(bound_identity[0], bound_identity[1])

    def arm(self) -> None:
        if self.state is AdmissionState.BOUND_NOT_ARMED and self.evidence.fatal_reason is None:
            self.state = AdmissionState.ARMED_WAIT_SEQUENCE_ZERO
            self.evidence.peer_armed = True

    def record_socket_error(self, phase: str, sequence: int | None, exc: BaseException) -> None:
        self.evidence.socket_errors.append(SocketErrorEvidence.from_exception(phase, sequence, exc))
        self.evidence.fatal_reason = BLOCKED_ASYNC

    def _base_row(self, packet: bytes, source: tuple[str, int], rx_ns: int) -> dict[str, object]:
        return {
            "state": self.state.value,
            "source_ip": source[0],
            "source_port": source[1],
            "packet_length": len(packet),
            "sequence": "",
            "error": "",
            "INGRESS_RX_MONOTONIC_NS": rx_ns,
            "INGRESS_SEND_ATTEMPT_MONOTONIC_NS": "",
            "INGRESS_SEND_RESULT_MONOTONIC_NS": "",
            "INGRESS_RX_TO_SEND_ATTEMPT_US": "",
            "INGRESS_SEND_CALL_US": "",
            "INGRESS_SEND_RESULT": "NOT_ATTEMPTED",
        }

    def observe(self, packet: bytes, source: tuple[str, int], rx_ns: int | None = None) -> dict[str, object]:
        if rx_ns is None:
            rx_ns = time.perf_counter_ns()
        row = self._base_row(packet, source, rx_ns)
        if self.evidence.fatal_reason:
            row["error"] = self.evidence.fatal_reason
            return row
        if self.state is AdmissionState.BOUND_NOT_ARMED:
            self.evidence.bound_not_armed_packet_count += 1
            return row
        if self.evidence.blocked_admission_sequence_miss:
            row["state"] = BLOCKED_ADMISSION_SEQUENCE_MISS
            row["error"] = BLOCKED_ADMISSION_SEQUENCE_MISS
            return row
        if self.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO:
            candidate = self.validator.pure_candidate(packet, source)
            if candidate is None:
                self.evidence.pre_admission_non_c1_count += 1
                row["error"] = "pre_admission_non_c1"
                return row
            row["sequence"] = candidate.sequence
            if candidate.sequence != 0:
                self.evidence.blocked_admission_sequence_miss = True
                self.evidence.fatal_reason = BLOCKED_ADMISSION_SEQUENCE_MISS
                row["state"] = BLOCKED_ADMISSION_SEQUENCE_MISS
                row["error"] = BLOCKED_ADMISSION_SEQUENCE_MISS
                return row
            self.state = AdmissionState.ADMITTED
            self.evidence.admission_sequence_zero_ok = True
            row["state"] = self.state.value
        return self._observe_admitted(packet, source, rx_ns, row)

    def _observe_admitted(
        self, packet: bytes, source: tuple[str, int], rx_ns: int, row: dict[str, object]
    ) -> dict[str, object]:
        if self.state is not AdmissionState.ADMITTED:
            self.evidence.unsolicited_send_total += 1
            row["error"] = "send_guard"
            return row
        frame, validation_error = self.validator.observe(packet, source)
        if frame is None:
            row["error"] = validation_error
            return row
        sequence = frame.sequence
        row["sequence"] = sequence
        self.evidence.ingress_attempt_total += 1
        if self.evidence.ingress_first_sequence is None:
            self.evidence.ingress_first_sequence = sequence
        self.evidence.ingress_last_sequence = sequence
        attempt_ns = time.perf_counter_ns()
        try:
            sent = self.sendto(packet, INGRESS_DESTINATION)
            result_ns = time.perf_counter_ns()
            if sent == FRAME_LENGTH:
                self.evidence.ingress_success_total += 1
                result = "SUCCESS"
            else:
                self.evidence.ingress_fail_total += 1
                self.evidence.fatal_reason = SEND_FAIL
                result = f"SHORT_SEND_{sent}"
        except OSError as exc:
            result_ns = time.perf_counter_ns()
            self.evidence.ingress_fail_total += 1
            self.record_socket_error("SENDTO", sequence, exc)
            result = "SOCKET_ERROR"
        timing = TimingEvidence(sequence, rx_ns, attempt_ns, result_ns, result)
        self.evidence.timings.append(timing)
        if not timing.valid:
            self.evidence.timing_evidence_valid = False
            if self.evidence.fatal_reason is None:
                self.evidence.fatal_reason = BLOCKED_EVIDENCE
        row.update(
            {
                "INGRESS_SEND_ATTEMPT_MONOTONIC_NS": attempt_ns,
                "INGRESS_SEND_RESULT_MONOTONIC_NS": result_ns,
                "INGRESS_RX_TO_SEND_ATTEMPT_US": f"{timing.rx_to_send_us:.3f}",
                "INGRESS_SEND_CALL_US": f"{timing.send_call_us:.3f}",
                "INGRESS_SEND_RESULT": result,
            }
        )
        if result != "SUCCESS":
            row["error"] = result
        return row

    def passed(self) -> bool:
        c = self.validator.counters
        e = self.evidence
        return (
            e.peer_complete
            and e.peer_armed
            and e.admission_sequence_zero_ok
            and not e.blocked_admission_sequence_miss
            and e.fatal_reason is None
            and c.valid_total > 0
            and c.first_sequence == 0
            and c.errors_zero()
            and e.ingress_attempt_total > 0
            and e.ingress_attempt_total == e.ingress_success_total
            and e.ingress_fail_total == 0
            and not e.socket_errors
            and e.unsolicited_send_total == 0
            and e.timing_evidence_valid
        )

    def result(self) -> str:
        if self.passed():
            return "PASS"
        if self.evidence.fatal_reason in {BLOCKED_ASYNC, BLOCKED_ADMISSION_SEQUENCE_MISS, BLOCKED_EVIDENCE}:
            return "BLOCKED"
        return "FAIL"

    def summary_lines(self) -> list[str]:
        c = self.validator.counters
        e = self.evidence
        first_error = e.socket_errors[0] if e.socket_errors else None
        rx_to_send = [item.rx_to_send_us for item in e.timings if item.valid]
        send_calls = [item.send_call_us for item in e.timings if item.valid]
        fmt = lambda value: "NONE" if value is None else str(value)
        return [
            f"PEER_COMPLETE={int(e.peer_complete)}",
            f"PEER_ARMED={int(e.peer_armed)}",
            f"ADMISSION_SEQUENCE_ZERO_OK={int(e.admission_sequence_zero_ok)}",
            f"BLOCKED_ADMISSION_SEQUENCE_MISS={int(e.blocked_admission_sequence_miss)}",
            f"BOUND_NOT_ARMED_PACKET_COUNT={e.bound_not_armed_packet_count}",
            f"PRE_ADMISSION_NON_C1_COUNT={e.pre_admission_non_c1_count}",
            f"VALID_DEVICE_TX_RX_TOTAL={c.valid_total}",
            f"FIRST_SEQUENCE={fmt(c.first_sequence)}",
            f"LAST_SEQUENCE={fmt(c.last_sequence)}",
            f"CRC_ERROR={c.crc_error}",
            f"LENGTH_ERROR={c.length_error}",
            f"FORMAT_ERROR={c.format_error}",
            f"PAYLOAD_ERROR={c.payload_error}",
            f"FLAGS_ERROR={c.flags_error}",
            f"UNEXPECTED_SOURCE={c.unexpected_source}",
            f"SOURCE_PORT_ERROR={c.source_port_error}",
            f"SEQ_GAP={c.seq_gap}",
            f"DUPLICATE={c.duplicate}",
            f"OUT_OF_ORDER={c.out_of_order}",
            f"INGRESS_TX_ATTEMPT_TOTAL={e.ingress_attempt_total}",
            f"INGRESS_TX_SUCCESS_TOTAL={e.ingress_success_total}",
            f"INGRESS_TX_FAIL_TOTAL={e.ingress_fail_total}",
            f"INGRESS_FIRST_SEQUENCE={fmt(e.ingress_first_sequence)}",
            f"INGRESS_LAST_SEQUENCE={fmt(e.ingress_last_sequence)}",
            f"PEER_BOUND_IP={e.bound_ip}",
            f"PEER_BOUND_PORT={'NA' if e.bound_port is None else e.bound_port}",
            f"INGRESS_SOURCE_IP={e.bound_ip}",
            f"INGRESS_SOURCE_PORT={'NA' if e.bound_port is None else e.bound_port}",
            f"INGRESS_DEST_IP={INGRESS_DESTINATION[0]}",
            f"INGRESS_DEST_PORT={INGRESS_DESTINATION[1]}",
            f"PEER_SOCKET_ERROR_TOTAL={len(e.socket_errors)}",
            f"PEER_SOCKET_ERROR_PHASE={first_error.phase if first_error else 'NONE'}",
            f"PEER_SOCKET_ERROR_SEQUENCE={fmt(first_error.sequence) if first_error else 'NA'}",
            f"PEER_SOCKET_ERROR_ERRNO={first_error.errno if first_error and first_error.errno is not None else 'NA'}",
            f"PEER_SOCKET_ERROR_WINERROR={first_error.winerror if first_error and first_error.winerror is not None else 'NA'}",
            "PEER_SOCKET_ERROR_MESSAGE=" + json.dumps(first_error.message if first_error else "", ensure_ascii=True),
            f"TIMING_EVIDENCE_VALID={int(e.timing_evidence_valid)}",
            f"INGRESS_RX_TO_SEND_MAX_US={max(rx_to_send, default=0.0):.3f}",
            f"INGRESS_RX_TO_SEND_P99_US={percentile_99(rx_to_send):.3f}",
            f"INGRESS_SEND_CALL_MAX_US={max(send_calls, default=0.0):.3f}",
            f"PEER_FATAL_REASON={e.fatal_reason or 'NONE'}",
            f"PEER_RESULT={self.result()}",
        ]


class FakeSocket:
    def __init__(
        self,
        identity: tuple[str, int] = REQUIRED_BIND,
        send_results: list[object] | None = None,
    ) -> None:
        self.identity = identity
        self.send_results = list(send_results or [])
        self.sent: list[tuple[bytes, tuple[str, int]]] = []

    def getsockname(self) -> tuple[str, int]:
        return self.identity

    def sendto(self, packet: bytes, destination: tuple[str, int]) -> int:
        self.sent.append((bytes(packet), destination))
        if self.send_results:
            result = self.send_results.pop(0)
            if isinstance(result, BaseException):
                raise result
            return int(result)
        return len(packet)


def validate_bound_identity(identity: tuple[str, int]) -> bool:
    return identity == REQUIRED_BIND


def _fixture_controller(fake: FakeSocket | None = None) -> tuple[DgBController, FakeSocket]:
    fake = fake or FakeSocket()
    return DgBController(fake.sendto, fake.getsockname()), fake


def run_self_test() -> int:
    tests: list[tuple[str, bool]] = []

    def check(name: str, condition: bool) -> None:
        tests.append((name, bool(condition)))

    valid0 = build_frame(0, 1234)
    check("c1ud_parser_valid", parse_frame(valid0).sequence == 0)
    for name, packet, error in (
        ("length_error", valid0[:-1], LengthError),
        ("magic_error", mutate_and_recrc(valid0, 0, ord("X")), MagicError),
        ("version_error", mutate_and_recrc(valid0, 4, 2), VersionError),
        ("gate_error", mutate_and_recrc(valid0, 5, 2), GateError),
        ("length_field_error", mutate_and_recrc(valid0, 7, 31), LengthError),
        ("payload_error", mutate_and_recrc(valid0, 16, valid0[16] ^ 1), PayloadError),
        ("flags_error", mutate_and_recrc(valid0, 6, 0x83), FlagsError),
    ):
        try:
            parse_frame(packet)
            check(name, False)
        except error:
            check(name, True)
    bad_crc = bytearray(valid0)
    bad_crc[30] ^= 1
    try:
        parse_frame(bytes(bad_crc))
        check("crc_error", False)
    except CrcError:
        check("crc_error", True)

    validator = StrictValidator()
    validator.observe(valid0, ("192.168.50.99", 50001))
    validator.observe(valid0, ("192.168.50.10", 50002))
    check("source_ip_error", validator.counters.unexpected_source == 1)
    check("source_port_error", validator.counters.source_port_error == 1)

    sequence_validator = StrictValidator()
    sequence_validator.observe(build_frame(0), EXPECTED_SOURCE)
    sequence_validator.observe(build_frame(1), EXPECTED_SOURCE)
    sequence_validator.observe(build_frame(1), EXPECTED_SOURCE)
    sequence_validator.observe(build_frame(3), EXPECTED_SOURCE)
    sequence_validator.observe(build_frame(2), EXPECTED_SOURCE)
    check("sequence_continuity", sequence_validator.counters.valid_total == 2)
    check("sequence_duplicate", sequence_validator.counters.duplicate == 1)
    check("sequence_gap", sequence_validator.counters.seq_gap == 1)
    check("sequence_out_of_order", sequence_validator.counters.out_of_order == 1)

    controller, fake = _fixture_controller()
    controller.observe(valid0, EXPECTED_SOURCE)
    check("bound_not_armed_suppresses_send", len(fake.sent) == 0)
    check("bound_not_armed_does_not_poison_strict", controller.validator.counters.rx_total == 0)
    controller.arm()
    check("arm_transition", controller.state is AdmissionState.ARMED_WAIT_SEQUENCE_ZERO)
    controller.observe(b"noise", EXPECTED_SOURCE)
    check("non_c1_pre_admission_noise", controller.evidence.pre_admission_non_c1_count == 1)
    controller.observe(valid0, EXPECTED_SOURCE)
    check("sequence_zero_admission", controller.state is AdmissionState.ADMITTED)
    check("first_admitted_send_once", len(fake.sent) == 1 and controller.evidence.ingress_attempt_total == 1)
    check("same_32_bytes", fake.sent[0][0] == valid0)
    check("destination_exact", fake.sent[0][1] == INGRESS_DESTINATION)

    blocked, blocked_fake = _fixture_controller()
    blocked.arm()
    blocked.observe(build_frame(9), EXPECTED_SOURCE)
    check("nonzero_first_sequence_blocked", blocked.evidence.blocked_admission_sequence_miss)
    check("nonzero_first_no_send", len(blocked_fake.sent) == 0)

    check("fake_getsockname_correct", validate_bound_identity(FakeSocket().getsockname()))
    check("fake_getsockname_wrong_blocked", not validate_bound_identity(FakeSocket(("0.0.0.0", 50001)).getsockname()))
    check("source_summary_from_getsockname", "PEER_BOUND_IP=192.168.50.30" in controller.summary_lines())

    short_fake = FakeSocket(send_results=[31])
    short, _ = _fixture_controller(short_fake)
    short.arm()
    short.observe(valid0, EXPECTED_SOURCE)
    check("short_send_attempt", short.evidence.ingress_attempt_total == 1)
    check("short_send_fail", short.evidence.ingress_fail_total == 1 and short.evidence.ingress_success_total == 0)
    check("short_send_no_retry", len(short_fake.sent) == 1)

    send_oserror = OSError(10054, "connection reset")
    send_fake = FakeSocket(send_results=[send_oserror])
    send_error, _ = _fixture_controller(send_fake)
    send_error.arm()
    send_error.observe(valid0, EXPECTED_SOURCE)
    check("sendto_oserror_recorded", len(send_error.evidence.socket_errors) == 1)
    check("sendto_oserror_no_retry", len(send_fake.sent) == 1)
    check("sendto_oserror_phase", send_error.evidence.socket_errors[0].phase == "SENDTO")

    recv_error, _ = _fixture_controller()
    recv_error.record_socket_error("RECVFROM", None, OSError(10054, "async reset"))
    check("recvfrom_oserror_recorded", len(recv_error.evidence.socket_errors) == 1)
    check("recvfrom_oserror_fatal", recv_error.evidence.fatal_reason == BLOCKED_ASYNC)

    absent_error, _ = _fixture_controller()
    absent_error.record_socket_error("RECVFROM", None, OSError("no numeric fields"))
    lines = absent_error.summary_lines()
    check("absent_errno_deterministic", "PEER_SOCKET_ERROR_ERRNO=NA" in lines)
    check("absent_winerror_deterministic", "PEER_SOCKET_ERROR_WINERROR=NA" in lines)

    controller.evidence.peer_complete = True
    timing = controller.evidence.timings[0]
    check("timing_order_valid", timing.valid)
    malformed = TimingEvidence(0, 30, 20, 40, "SUCCESS")
    check("timing_order_malformed", not malformed.valid)
    check("p99_nearest_rank", percentile_99([1.0, 2.0, 3.0, 100.0]) == 100.0)
    check("attempt_success_semantics", controller.evidence.ingress_attempt_total == controller.evidence.ingress_success_total == 1)
    check("peer_result_positive_allowlist", controller.result() == "PASS")
    check("blocked_result_closed_world", recv_error.result() == "BLOCKED")

    passed = sum(1 for _, ok in tests if ok)
    for name, ok in tests:
        print(f"PEER_OFFLINE_TEST name={name} result={'PASS' if ok else 'FAIL'}")
    print(f"PEER_OFFLINE_TEST_TOTAL={len(tests)}")
    print(f"PEER_OFFLINE_TEST_PASS={passed}")
    print(f"PEER_OFFLINE_TEST_FAIL={len(tests) - passed}")
    print(f"PEER_OFFLINE_RESULT={'PASS' if passed == len(tests) else 'FAIL'}")
    return EXIT_PASS if passed == len(tests) else EXIT_FAIL


def _write_summary(controller: DgBController) -> None:
    for line in controller.summary_lines():
        print(line, flush=True)


def run_live(args: argparse.Namespace) -> int:
    """Future authorized live path.  Never used by --self-test."""
    arm_file = Path(args.arm_file)
    armed_file = Path(args.armed_file)
    ready_file = Path(args.ready_file)
    stop_file = Path(args.stop_file)
    csv_path = Path(args.csv)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.25)
    controller: DgBController | None = None
    owned_stream: TextIO | None = None
    fieldnames = [
        "state", "source_ip", "source_port", "packet_length", "sequence", "error",
        "INGRESS_RX_MONOTONIC_NS", "INGRESS_SEND_ATTEMPT_MONOTONIC_NS",
        "INGRESS_SEND_RESULT_MONOTONIC_NS", "INGRESS_RX_TO_SEND_ATTEMPT_US",
        "INGRESS_SEND_CALL_US", "INGRESS_SEND_RESULT",
    ]
    try:
        try:
            sock.bind((args.bind_ip, args.port))
        except OSError as exc:
            controller = DgBController(lambda _p, _d: 0, ("NA", 0))
            controller.record_socket_error("BIND", None, exc)
            print(f"PEER_SOCKET_RAW_ERROR={exc!r}", file=sys.stderr, flush=True)
            controller.evidence.peer_complete = True
            _write_summary(controller)
            return EXIT_BLOCKED_CONTROL
        try:
            actual = sock.getsockname()
        except OSError as exc:
            controller = DgBController(lambda _p, _d: 0, ("NA", 0))
            controller.record_socket_error("GETSOCKNAME", None, exc)
            print(f"PEER_SOCKET_RAW_ERROR={exc!r}", file=sys.stderr, flush=True)
            controller.evidence.peer_complete = True
            _write_summary(controller)
            return EXIT_BLOCKED_CONTROL
        controller = DgBController(sock.sendto, (str(actual[0]), int(actual[1])))
        if not validate_bound_identity((str(actual[0]), int(actual[1]))):
            controller.evidence.fatal_reason = BLOCKED_EVIDENCE
            controller.evidence.peer_complete = True
            print(f"PEER_BOUND_IDENTITY_MISMATCH actual={actual!r} expected={REQUIRED_BIND!r}", file=sys.stderr, flush=True)
            _write_summary(controller)
            return EXIT_BLOCKED_CONTROL

        owned_stream = csv_path.open("w", newline="", encoding="utf-8")
        writer = csv.DictWriter(owned_stream, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        ready_file.write_text("PEER_READY=1\n", encoding="utf-8")
        print(
            f"PEER_READY=1 STATE=BOUND_NOT_ARMED PEER_BOUND_IP={actual[0]} PEER_BOUND_PORT={actual[1]}",
            file=sys.stderr,
            flush=True,
        )
        while True:
            if stop_file.exists():
                print("PEER_STOP_FILE_OBSERVED=1", file=sys.stderr, flush=True)
                break
            if controller.state is AdmissionState.BOUND_NOT_ARMED and arm_file.exists():
                controller.arm()
                armed_file.write_text("PEER_ARMED=1\n", encoding="utf-8")
                print("PEER_ARMED=1", file=sys.stderr, flush=True)
            try:
                packet, source = sock.recvfrom(65535)
                rx_ns = time.perf_counter_ns()
            except socket.timeout:
                continue
            except OSError as exc:
                controller.record_socket_error("RECVFROM", None, exc)
                print(f"PEER_SOCKET_RAW_ERROR={exc!r}", file=sys.stderr, flush=True)
                break
            row = controller.observe(packet, (str(source[0]), int(source[1])), rx_ns)
            writer.writerow(row)
            owned_stream.flush()
            if row.get("INGRESS_SEND_RESULT") == "SOCKET_ERROR":
                error = controller.evidence.socket_errors[-1]
                print(
                    "PEER_SOCKET_RAW_ERROR="
                    f"phase={error.phase} sequence={error.sequence!r} "
                    f"errno={error.errno!r} winerror={error.winerror!r} message={error.message!r}",
                    file=sys.stderr,
                    flush=True,
                )
            if controller.evidence.fatal_reason:
                break
    finally:
        if controller is not None:
            controller.evidence.peer_complete = True
        if owned_stream is not None:
            owned_stream.flush()
            owned_stream.close()
        sock.close()
    assert controller is not None
    _write_summary(controller)
    if controller.passed():
        return EXIT_PASS
    if controller.evidence.blocked_admission_sequence_miss:
        return EXIT_BLOCKED_ADMISSION
    if controller.evidence.fatal_reason in {BLOCKED_ASYNC, BLOCKED_EVIDENCE}:
        return EXIT_BLOCKED_CONTROL
    return EXIT_FAIL


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--bind-ip", default=REQUIRED_BIND[0])
    parser.add_argument("--port", type=int, default=REQUIRED_BIND[1])
    parser.add_argument("--arm-file")
    parser.add_argument("--armed-file")
    parser.add_argument("--ready-file")
    parser.add_argument("--stop-file")
    parser.add_argument("--csv")
    args = parser.parse_args()
    if args.self_test == args.live:
        parser.error("select exactly one of --self-test or --live")
    if args.live:
        for name in ("arm_file", "armed_file", "ready_file", "stop_file", "csv"):
            if not getattr(args, name):
                parser.error(f"--live requires --{name.replace('_', '-')}")
    return args


if __name__ == "__main__":
    parsed = parse_args()
    raise SystemExit(run_self_test() if parsed.self_test else run_live(parsed))
