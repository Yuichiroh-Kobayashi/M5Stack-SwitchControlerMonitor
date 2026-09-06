"""Offline adjudication. Missing telemetry/decisions cannot become a pass."""
import csv
import math
from pathlib import Path

from .mapping import load_serial, parse_fields, sample, neutral
from .peer import DEVICE, PORT, classify, wire


def passive(serial_path: Path) -> dict:
    entries = load_serial(serial_path)
    rows = [(e['elapsed_ns'], parse_fields(e['line'])) for e in entries
            if e['line'].startswith('[SENDER] ')]
    samples = [s for e in entries if (s := sample(e)) is not None]
    required = ['UPTIME', 'HID_READY', 'INPUT_VALID', 'VID', 'PID', 'HID_REPORT_TOTAL',
                'HID_READY_DROP', 'HID_STALL', 'USB_STATE', 'HID_AGE_MS', 'CONTROL_TX']
    if len(rows) < 2 or rows[-1][0] - rows[0][0] < 60e9 or len(samples) < 60 or any(not all(k in v for k in required) for _, v in rows):
        return {'result': 'INCOMPLETE', 'reason': 'Need 60s of complete USB intake telemetry', 'physical_qualification': False}
    checks = {
        'ready_valid': all(v['HID_READY'] == v['INPUT_VALID'] == '1' and v['VID'] == '0F0D' and v['PID'] == '0202' and v['USB_STATE'] == '90' and int(v['HID_AGE_MS']) < 100 for _, v in rows),
        'neutral_samples': all(neutral(s) for s in samples),
        'no_malformed_input': len(samples) == sum(e['line'].startswith('USB_INTAKE_INPUT ') for e in entries),
        'sample_coverage': samples[-1]['elapsed_ns'] - samples[0]['elapsed_ns'] >= 60e9 and all(0 < b['elapsed_ns'] - a['elapsed_ns'] <= 1.5e9 for a, b in zip(samples, samples[1:])),
        'reports_continue': all(int(b['HID_REPORT_TOTAL']) > int(a['HID_REPORT_TOTAL']) and 0 < ((int(b['UPTIME']) - int(a['UPTIME'])) & 0xffffffff) <= 1500 for (_, a), (_, b) in zip(rows, rows[1:])),
        'serial_coverage': all(0 < b[0] - a[0] <= 1.5e9 for a, b in zip(rows, rows[1:])),
        'no_loss_or_transport': all(int(v['HID_READY_DROP']) == int(v['HID_STALL']) == int(v['CONTROL_TX']) == 0 for _, v in rows),
    }
    return {'result': 'PASSIVE_DATA_PASS' if all(checks.values()) else 'FAIL', 'checks': checks,
            'samples': len(samples), 'reports_delta': int(rows[-1][1]['HID_REPORT_TOTAL']) - int(rows[0][1]['HID_REPORT_TOTAL']),
            'physical_qualification': False, 'note': 'Passive neutral capture is not manual mapping qualification.'}


def wire_events_valid(events: list[dict], message_type: int) -> bool:
    previous = None
    previous_host = None
    for event in events:
        try:
            frame = wire.decode(bytes.fromhex(event['hex']))
            now = int(event['host_ns'])
            relation, _ = classify(previous, int(frame['sequence']))
            if frame['message_type'] != message_type or int(event['length']) != 32 or int(event['sequence']) != frame['sequence'] or relation not in ('first', 'in_order') or (previous_host is not None and now <= previous_host):
                return False
            if message_type == wire.CONTROL:
                if not frame['control_flags'] & 1:
                    return False
            elif frame['status_flags'] != 11 or frame['uart_state'] != 0 or frame['control_age_ms'] >= 100:
                return False
            previous, previous_host = int(frame['sequence']), now
        except (ValueError, KeyError, TypeError):
            return False
    return True

LIMIT_KEYS = ['max_packet_gap_ms', 'max_sender_lateness_ms', 'max_peer_lateness_ms',
              'max_lcd_dirty_ms', 'max_lcd_unit_us', 'max_schedule_skips']


def validate_limits(limits: dict) -> None:
    if limits.get('decision') != 'approved' or not str(limits.get('authority', '')).strip():
        raise ValueError('Timing acceptance is not approved/frozen')
    for name in LIMIT_KEYS:
        value = limits.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f'Missing/invalid timing limit: {name}')


def read_peer(path: Path) -> list[dict]:
    with path.open(encoding='utf-8-sig', newline='') as source:
        return list(csv.DictReader(source))


def screening(serial_path: Path, peer_path: Path, period_ms: int, limits: dict,
              warmup_seconds: float = 10) -> dict:
    validate_limits(limits)
    if period_ms not in (10, 20) or not 0 <= warmup_seconds <= 30:
        raise ValueError('Invalid screening period/warmup')
    start = int(warmup_seconds * 1e9)
    serial = [entry for entry in load_serial(serial_path) if entry['elapsed_ns'] >= start]
    peer = [entry for entry in read_peer(peer_path) if int(entry['elapsed_ns']) >= start]
    groups = {}
    for key, prefix in [('sender', '[SENDER] '), ('runtime', 'TRANSPORT_PERIOD_MS='),
                        ('lcd', 'LCD_SNAPSHOT_MAX_MS='), ('profile', 'BUILD_PROFILE=')]:
        groups[key] = [(entry['elapsed_ns'], parse_fields(entry['line'])) for entry in serial if entry['line'].startswith(prefix)]
    required = {'sender': ['UPTIME', 'HID_READY', 'INPUT_VALID', 'VID', 'PID', 'HID_REPORT_TOTAL',
                          'HID_READY_DROP', 'HID_STALL', 'CONTROL_TX', 'CONTROL_TX_FAIL', 'STATUS_RX',
                          'STATUS_VALID', 'STATUS_TIMEOUT', 'STATUS_CRC_FAIL', 'STATUS_SEQ_GAP',
                          'CONTROL_SCHEDULE_SKIP', 'LINK', 'RESET', 'USB_STATE', 'HID_AGE_MS'],
                'runtime': ['TRANSPORT_PERIOD_MS', 'MAX_SEND_LATE_MS', 'LCD_MAX_US'],
                'lcd': ['LCD_SNAPSHOT_MAX_MS', 'LCD_DIRTY_MAX_MS', 'LCD_PENDING_MS'],
                'profile': ['BUILD_PROFILE', 'PC_PEER_LAST_OCTET', 'PHY_OK']}
    for key, names in required.items():
        if len(groups[key]) < 2 or any(not all(name in values for name in names) for _, values in groups[key]) or groups[key][-1][0] - groups[key][0][0] < 60e9 or any(not 0 < b[0] - a[0] <= 1.5e9 for a, b in zip(groups[key], groups[key][1:])):
            return {'result': 'INCOMPLETE', 'reason': f'Missing/malformed {key} telemetry', 'physical_qualification': False}
    rows = groups['sender']
    span_ns = rows[-1][0] - rows[0][0]
    rx = [entry for entry in peer if entry['kind'] == 'rx']
    tx = [entry for entry in peer if entry['kind'] == 'tx']
    if span_ns < 60e9 or len(rx) < 2 or len(tx) < 2 or any(int(events[-1]['host_ns']) - int(events[0]['host_ns']) < 60e9 for events in (rx, tx)):
        return {'result': 'INCOMPLETE', 'reason': 'Need >=60s complete serial and bidirectional peer data', 'physical_qualification': False}
    def rate(events):
        span = int(events[-1]['host_ns']) - int(events[0]['host_ns'])
        return (len(events) - 1) * 1e9 / span if span > 0 else 0
    def max_gap(events):
        return max((int(b['host_ns']) - int(a['host_ns'])) / 1e6 for a, b in zip(events, events[1:]))
    error_fields = ['HID_READY_DROP', 'HID_STALL', 'CONTROL_TX_FAIL', 'STATUS_CRC_FAIL', 'STATUS_SEQ_GAP']
    counter_deltas = {name: int(rows[-1][1][name]) - int(rows[0][1][name]) for name in error_fields + ['CONTROL_SCHEDULE_SKIP', 'CONTROL_TX', 'STATUS_RX', 'HID_REPORT_TOTAL']}
    sender_span = ((int(rows[-1][1]['UPTIME']) - int(rows[0][1]['UPTIME'])) & 0xffffffff) / 1000
    low, high = (95, 105) if period_ms == 10 else (45, 55)
    rates = {'peer_control_hz': rate(rx), 'peer_status_hz': rate(tx),
             'sender_control_hz': counter_deltas['CONTROL_TX'] / sender_span if sender_span else 0,
             'sender_status_hz': counter_deltas['STATUS_RX'] / sender_span if sender_span else 0}
    maximums = {'control_gap_ms': max_gap(rx), 'status_gap_ms': max_gap(tx),
                'sender_lateness_ms': max(int(v['MAX_SEND_LATE_MS']) for _, v in groups['runtime']),
                'peer_lateness_ms': max(int(v['deadline_late_ns']) for v in tx) / 1e6,
                'lcd_unit_us': max(int(v['LCD_MAX_US']) for _, v in groups['runtime']),
                'lcd_dirty_ms': max(max(int(v['LCD_DIRTY_MAX_MS']), int(v['LCD_PENDING_MS'])) for _, v in groups['lcd']),
                'lcd_snapshot_ms': max(int(v['LCD_SNAPSHOT_MAX_MS']) for _, v in groups['lcd'])}
    checks = {
        'nominal_rates': all(low <= value <= high for value in rates.values()),
        'ready_valid_link': all(v['HID_READY'] == v['INPUT_VALID'] == v['STATUS_VALID'] == '1' and v['STATUS_TIMEOUT'] == '0' and v['VID'] == '0F0D' and v['PID'] == '0202' and v['USB_STATE'] == '90' and v['LINK'] == 'ON' and int(v['HID_AGE_MS']) < 100 for _, v in rows),
        'correct_test_profile': all(v['BUILD_PROFILE'] == 'PC_PEER_FIXED10HALF' and v['PC_PEER_LAST_OCTET'] == '30' and v['PHY_OK'] == '1' for _, v in groups['profile']),
        'correct_period': all(int(v['TRANSPORT_PERIOD_MS']) == period_ms for _, v in groups['runtime']),
        'no_error_increments': all(counter_deltas[name] == 0 for name in error_fields),
        'reports_continue': all(int(b['HID_REPORT_TOTAL']) > int(a['HID_REPORT_TOTAL']) and 0 < ((int(b['UPTIME']) - int(a['UPTIME'])) & 0xffffffff) <= 1500 for (_, a), (_, b) in zip(rows, rows[1:])),
        'no_serial_record_gap': all(0 < b[0] - a[0] <= 1_500_000_000 for a, b in zip(rows, rows[1:])),
        'peer_data_valid': all(v['result'] in ('first', 'in_order') and v['address'] == DEVICE and int(v['port']) == PORT and v['control_valid'] == '1' for v in rx),
        'wire_control_valid': wire_events_valid(rx, wire.CONTROL),
        'wire_status_valid': wire_events_valid(tx, wire.STATUS),
        'peer_status_valid': all(v['result'] == 'sent' and v['control_valid'] == '1' and v['control_timeout'] == '0' for v in tx),
        'no_peer_timeout': not any(v['kind'] == 'timeout' for v in peer),
        'no_reset_observed': len({v['RESET'] for _, v in rows}) == 1 and not any(v['RESET'] in ('PANIC', 'WDT') for _, v in rows),
        'skip_budget': 0 <= counter_deltas['CONTROL_SCHEDULE_SKIP'] <= limits['max_schedule_skips'] and sum(int(v['skipped']) for v in tx) <= limits['max_schedule_skips'],
        'packet_gap_budget': 0 < maximums['control_gap_ms'] <= limits['max_packet_gap_ms'] and 0 < maximums['status_gap_ms'] <= limits['max_packet_gap_ms'],
        'sender_lateness_budget': maximums['sender_lateness_ms'] <= limits['max_sender_lateness_ms'],
        'peer_lateness_budget': maximums['peer_lateness_ms'] <= limits['max_peer_lateness_ms'],
        'lcd_budget': maximums['lcd_dirty_ms'] <= limits['max_lcd_dirty_ms'] and maximums['lcd_unit_us'] <= limits['max_lcd_unit_us'],
    }
    return {'result': 'SCREEN_DATA_PASS' if all(checks.values()) else 'FAIL', 'checks': checks,
            'rates': rates, 'maximums': maximums, 'counter_deltas': counter_deltas,
            'initial_window_counters': {name: int(rows[0][1][name]) for name in error_fields},
            'serial_window_seconds': span_ns / 1e9, 'warmup_seconds': warmup_seconds,
            'physical_qualification': False,
            'limits': 'Data screening only. Manual mapping, preflight/artifact identity, physical Receiver/UART, fault and durability gates remain separate.'}
