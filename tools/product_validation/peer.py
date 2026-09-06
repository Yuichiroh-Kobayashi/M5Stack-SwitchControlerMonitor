"""32-byte CR-v1 Windows test peer; independent of historical C1/DG formats."""
from __future__ import annotations

import csv
import json
import select
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path

import core_protocol_reference as wire

PORT = 50001
DEVICE = '192.168.50.10'
PEER = '192.168.50.30'
TIMEOUT_NS = 100_000_000
CSV_FIELDS = ['kind', 'host_ns', 'elapsed_ns', 'address', 'port', 'length', 'hex',
              'result', 'sequence', 'source_uptime_ms', 'control_valid',
              'control_timeout', 'missing', 'deadline_late_ns', 'skipped', 'send_done_ns']


def classify(previous: int | None, current: int) -> tuple[str, int]:
    """Same uint16 relation/half-range boundary as CoreProtocol.cpp."""
    if previous is None:
        return 'first', 0
    delta = (current - previous) & 0xffff
    if not delta:
        return 'duplicate', 0
    if delta == 1:
        return 'in_order', 0
    return ('gap', delta - 1) if delta < 0x8000 else ('reverse', 0)


@dataclass
class Deadline:
    period_ns: int
    next_ns: int

    def take(self, now: int) -> tuple[int, int] | None:
        if now < self.next_ns:
            return None
        late = now - self.next_ns
        skipped = late // self.period_ns
        self.next_ns += (skipped + 1) * self.period_ns
        return late, skipped


@dataclass
class PeerState:
    last_sequence: int | None = None
    reported_sequence: int = 0
    last_control_ns: int | None = None
    input_valid: bool = False
    timed_out: bool = True
    status_sequence: int = 0
    counts: dict[str, int] = field(default_factory=lambda: dict(
        accepted=0, crc=0, invalid=0, unexpected_source=0, duplicate=0,
        reverse=0, gap=0, timeout=0, status_sent=0, send_error=0, schedule_skip=0))

    def expire(self, now: int) -> bool:
        if self.last_control_ns is not None and now - self.last_control_ns >= TIMEOUT_NS:
            if not self.timed_out:
                self.counts['timeout'] += 1
                self.timed_out = True
                self.input_valid = False
                # Match the product Receiver's sequence baseline reset on silence.
                self.last_sequence = None
                return True
        return False

    def accept(self, data: bytes, address: tuple[str, int], now: int) -> dict:
        self.expire(now)
        event = {'result': 'invalid', 'missing': 0}
        if address != (DEVICE, PORT):
            self.counts['unexpected_source'] += 1
            return {**event, 'result': 'unexpected_source'}
        try:
            frame = wire.decode(data)
            if frame['message_type'] != wire.CONTROL:
                raise ValueError('bad message type')
        except ValueError as exc:
            category = 'crc' if 'CRC' in str(exc) else 'invalid'
            self.counts[category] += 1
            return {**event, 'result': category}
        sequence = int(frame['sequence'])
        relation, missing = classify(self.last_sequence, sequence)
        event.update(result=relation, sequence=sequence,
                     source_uptime_ms=frame['uptime_ms'], missing=missing)
        if relation in ('duplicate', 'reverse'):
            self.counts[relation] += 1
            return event  # Rejected packets never refresh freshness.
        self.counts['accepted'] += 1
        self.counts['gap'] += missing
        self.last_sequence = self.reported_sequence = sequence
        self.last_control_ns = now
        self.input_valid = bool(int(frame['control_flags']) & 1)
        self.timed_out = False
        return event

    def status(self, now: int, started_ns: int) -> bytes:
        self.expire(now)
        # This is a PC peer, not a physical UART receiver: UART bit/state stay 0.
        flags = 1 | 8 | (2 if self.input_valid else 0) | (4 if self.timed_out else 0)
        if self.counts['crc'] or self.counts['invalid'] or self.counts['unexpected_source']:
            flags |= 32
        if self.counts['gap']:
            flags |= 64
        age = 65535 if self.timed_out or self.last_control_ns is None else min(65535, (now - self.last_control_ns) // 1_000_000)
        frame = bytearray(32)
        frame[:4] = b'CR\x01\x02'
        frame[4:6] = self.status_sequence.to_bytes(2, 'big')
        frame[6:10] = (((now - started_ns) // 1_000_000) & 0xffffffff).to_bytes(4, 'big')
        for offset, value in [(10, flags), (12, self.reported_sequence), (14, age),
                              (16, min(65535, self.counts['gap'])),
                              (18, min(65535, self.counts['crc'] + self.counts['invalid'] + self.counts['unexpected_source']))]:
            frame[offset:offset + 2] = value.to_bytes(2, 'big')
        frame[20] = 255
        return wire.finish(frame)


def run_peer(request: dict) -> dict:
    """Called only by explicit `peer` CLI. Test imports/replays never call this."""
    from .mapping import validate_review
    if request.get('operation') != 'lan_screen' or request.get('period_ms') not in (10, 20):
        raise ValueError('Explicit LAN screening request and 10/20ms period required')
    if request.get('bind') != PEER or request.get('device') != DEVICE or request.get('port') != PORT:
        raise ValueError('PC test addresses/port must match the fixed profile')
    validate_review(Path(request['mapping_review']), request['controller_profile_sha256'], request['expected_pnp_id'], request['source_manifest_sha256'])
    limits = json.loads(Path(request['limits']).read_text(encoding='utf-8-sig'))
    from .analysis import validate_limits
    validate_limits(limits)
    duration = float(request['duration_seconds'])
    if not 65 <= duration <= 603:
        raise ValueError('Screening duration must be 65..603 seconds including startup allowance')
    root = Path(request['output_root']).resolve()
    if not root.is_dir() or (root / 'peer.csv').exists():
        raise ValueError('Use an existing fresh trial root without peer.csv')
    state = PeerState()
    started = time.perf_counter_ns()
    period = int(request['period_ms']) * 1_000_000
    schedule = Deadline(period, started + period)
    deadline = started + int(duration * 1_000_000_000)
    last_flush = started
    with (root / 'peer.csv').open('x', newline='', encoding='utf-8') as output, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        # No SO_REUSEADDR: an occupied test port must fail, never share traffic.
        sock.bind((PEER, PORT))
        sock.setblocking(False)
        writer = csv.DictWriter(output, fieldnames=CSV_FIELDS)
        writer.writeheader()
        (root / 'peer.ready').write_text(str(started), encoding='ascii')

        def write(kind: str, now: int, **fields):
            writer.writerow(dict(kind=kind, host_ns=now, elapsed_ns=now - started, **fields))

        while (now := time.perf_counter_ns()) < deadline and not (root / 'peer.stop').exists():
            if state.expire(now):
                write('timeout', now, result='control_timeout')
            due = schedule.take(now)
            if due is not None:
                late, skipped = due
                state.counts['schedule_skip'] += skipped
                data = state.status(now, started)
                result = 'sent'
                try:
                    if sock.sendto(data, (DEVICE, PORT)) != 32:
                        raise OSError('short UDP send')
                    state.counts['status_sent'] += 1
                    state.status_sequence = (state.status_sequence + 1) & 0xffff
                except OSError:
                    state.counts['send_error'] += 1
                    result = 'send_error'
                write('tx', now, address=DEVICE, port=PORT, length=32, hex=data.hex().upper(),
                      sequence=int.from_bytes(data[4:6], 'big'), result=result,
                      control_valid=int(state.input_valid), control_timeout=int(state.timed_out),
                      deadline_late_ns=late, skipped=skipped, send_done_ns=time.perf_counter_ns())
            # Bounded receive work; never starve the next transmit deadline.
            for _ in range(32):
                try:
                    data, address = sock.recvfrom(2048)
                except BlockingIOError:
                    break
                observed = time.perf_counter_ns()
                event = state.accept(data, address, observed)
                write('rx', observed, address=address[0], port=address[1], length=len(data),
                      hex=data.hex().upper(), control_valid=int(state.input_valid),
                      control_timeout=int(state.timed_out), **event)
                if observed >= schedule.next_ns:
                    break
            now = time.perf_counter_ns()
            if now - last_flush >= 1_000_000_000:
                output.flush()
                last_flush = now
            wait = max(0, min(0.005, (schedule.next_ns - now) / 1e9))
            if wait:
                select.select([sock], [], [], wait)
    summary = dict(source='WINDOWS_PEER_NOT_PHYSICAL_RECEIVER', counts=state.counts,
                   duration_seconds=(time.perf_counter_ns() - started) / 1e9,
                   monotonic_clock=time.get_clock_info('perf_counter')._asdict()
                   if hasattr(time.get_clock_info('perf_counter'), '_asdict') else vars(time.get_clock_info('perf_counter')))
    (root / 'peer-summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return summary
