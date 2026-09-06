"""Offline replay only: no ports, sockets or physical qualification."""
import csv
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from product_validation import analysis, evidence, mapping, peer


def control(seq=0):
    data = bytearray(peer.wire.control_frame(seq, seq * 20))
    data[11] = 1
    return peer.wire.finish(data)


class PeerTests(unittest.TestCase):
    def test_timeout_rejections_and_restart(self):
        state = peer.PeerState()
        self.assertEqual(state.accept(control(65535), (peer.DEVICE, peer.PORT), 0)['result'], 'first')
        self.assertEqual(state.accept(control(0), (peer.DEVICE, peer.PORT), 20_000_000)['result'], 'in_order')
        self.assertEqual(state.accept(control(0), (peer.DEVICE, peer.PORT), 90_000_000)['result'], 'duplicate')
        bad = bytearray(control(1)); bad[15] ^= 1
        self.assertEqual(state.accept(bytes(bad), (peer.DEVICE, peer.PORT), 100_000_000)['result'], 'crc')
        self.assertEqual(state.accept(control(1), ('192.168.50.99', peer.PORT), 110_000_000)['result'], 'unexpected_source')
        self.assertFalse(state.expire(119_999_999))
        self.assertTrue(state.expire(120_000_000))
        status = peer.wire.decode(state.status(120_000_000, 0))
        self.assertEqual(status['status_flags'] & 6, 4)
        self.assertEqual(status['uart_state'], 0)
        self.assertEqual(state.accept(control(30000), (peer.DEVICE, peer.PORT), 130_000_000)['result'], 'first')

    def test_sequence_and_no_catchup(self):
        for previous, current, result in [(0, 0, 'duplicate'), (0, 32768, 'reverse'), (0, 32767, 'gap'), (65535, 0, 'in_order')]:
            self.assertEqual(peer.classify(previous, current)[0], result)
        deadline = peer.Deadline(10, 100)
        self.assertEqual(deadline.take(139), (39, 3))
        self.assertEqual(deadline.next_ns, 140)
        self.assertIsNone(deadline.take(139))

    def test_missing_gate_never_opens_socket(self):
        from unittest.mock import patch
        with patch('socket.socket', side_effect=AssertionError('socket forbidden')):
            with self.assertRaises(ValueError):
                peer.run_peer({})


class EvidenceTests(unittest.TestCase):
    def test_nested_manifest_and_tamper(self):
        (ROOT / 'build-temp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'build-temp') as parent:
            root = Path(parent) / 'trial'; root.mkdir()
            (root / 'nested').mkdir()
            file = root / 'nested/manifest.json'; file.write_text('{}')
            result = evidence.finalize(root)
            self.assertEqual(result['file_count'], 1)
            evidence.verify(root)
            with self.assertRaises(ValueError): evidence.finalize(root)
            file.write_text('{"changed":true}')
            with self.assertRaises(ValueError): evidence.verify(root)

    def test_escape_rejected(self):
        with self.assertRaises(ValueError): evidence.trial_path(ROOT)


class MappingTests(unittest.TestCase):
    def test_hold_release_and_malformed_observation(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'serial.jsonl'
            lines = []
            for second in range(16):
                pressed = 4 <= second < 10
                line = 'USB_INTAKE_INPUT RAW=' + ('04000F8080808000' if pressed else '00000F8080808000') + ' LEN=8 COPIED=8 ID_FLAG=0 VALID=1 DP=8 LX=128 LY=128 RX=128 RY=128 LT=0 RT=0 BUTTONS=' + ('0001' if pressed else '0000')
                lines.append(dict(elapsed_ns=second*1_000_000_000, line=line))
            path.write_text(''.join(json.dumps(row)+'\n' for row in lines))
            self.assertEqual(mapping.analyze_step(path, 'A', {})['result'], 'OBSERVED_MATCH')
            lines[-1]['line'] = lines[7]['line']
            path.write_text(''.join(json.dumps(row)+'\n' for row in lines))
            self.assertEqual(mapping.analyze_step(path, 'A', {})['result'], 'INCOMPLETE_OR_MISMATCH')
            lines[-1]['line'] = 'USB_INTAKE_INPUT broken'
            path.write_text(''.join(json.dumps(row)+'\n' for row in lines))
            self.assertEqual(mapping.analyze_step(path, 'A', {})['result'], 'INCOMPLETE_OR_MISMATCH')

    def test_descriptor_fixture(self):
        fixture = json.loads((ROOT / 'tests/product/fixtures/hori-0f0d-0202-switch2.json').read_text())
        for name in ('report', 'configuration'):
            self.assertEqual(hashlib.sha256(bytes.fromhex(fixture[name + '_descriptor_hex'])).hexdigest().upper(), fixture[name + '_descriptor_sha256'])
        self.assertEqual(len(bytes.fromhex(fixture['neutral_hex'])), 8)
        self.assertEqual(len(fixture['buttons']), 14)

    def test_review_requires_all_physical_steps_and_candidate(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = []
            for step in mapping.REQUIRED:
                path = Path(temp) / (step + '.json')
                path.write_text(json.dumps(dict(schema='core-mapping-step-v1', step=step, result='OBSERVED_MATCH', trial_kind='physical_usb_mapping', controller_profile_sha256='B'*64, source_manifest_sha256='A'*64, expected_pnp_id='OFFLINE_FIXTURE')))
                paths.append(path)
            with self.assertRaises(ValueError): mapping.make_review(paths[:-1], 'test', 'unknown', True)
            with self.assertRaises(ValueError): mapping.make_review(paths, 'test', 'unknown', False)
            review = mapping.make_review(paths, 'OFFLINE TEST ONLY', 'unknown/ignored', True)
            output = Path(temp) / 'review.json'; output.write_text(json.dumps(review))
            mapping.validate_review(output, 'B'*64, 'OFFLINE_FIXTURE', 'A'*64)
            with self.assertRaises(ValueError): mapping.validate_review(output, 'B'*64, 'OFFLINE_FIXTURE', 'C'*64)
            paths[0].write_text('{}')
            with self.assertRaises((ValueError, KeyError)): mapping.validate_review(output, 'B'*64, 'OFFLINE_FIXTURE', 'A'*64)


class ScreeningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.limits = dict(decision='approved', authority='OFFLINE TEST ONLY', **{k: 100 for k in analysis.LIMIT_KEYS})
        self.limits['max_schedule_skips'] = 0
        self.serial = []
        for second in range(72):
            fields = dict(UPTIME=second*1000, HID_READY=1, INPUT_VALID=1, VID='0F0D', PID='0202', HID_REPORT_TOTAL=second*200, HID_READY_DROP=0, HID_STALL=0, CONTROL_TX=second*50, CONTROL_TX_FAIL=0, STATUS_RX=second*50, STATUS_VALID=1, STATUS_TIMEOUT=0, STATUS_CRC_FAIL=0, STATUS_SEQ_GAP=0, CONTROL_SCHEDULE_SKIP=0, LINK='ON', RESET='POWERON', USB_STATE='90', HID_AGE_MS=5)
            for line in ('[SENDER] ' + ' '.join(f'{k}={v}' for k,v in fields.items()), 'TRANSPORT_PERIOD_MS=20 MAX_SEND_LATE_MS=0 LCD_MAX_US=50', 'LCD_SNAPSHOT_MAX_MS=1 LCD_DIRTY_MAX_MS=2 LCD_PENDING_MS=0', 'BUILD_PROFILE=PC_PEER_FIXED10HALF PC_PEER_LAST_OCTET=30 PHY_OK=1'):
                self.serial.append(dict(elapsed_ns=second*1_000_000_000, line=line))
        self.events = []
        state = peer.PeerState()
        for seq in range(3601):
            now = seq*20_000_000
            packet = control(seq)
            state.accept(packet, (peer.DEVICE, peer.PORT), now)
            state.status_sequence = seq
            for kind, data, result in [('rx', packet, 'first' if seq == 0 else 'in_order'), ('tx', state.status(now, 0), 'sent')]:
                self.events.append(dict(kind=kind, host_ns=now+1_000_000_000, elapsed_ns=now, address=peer.DEVICE, port=peer.PORT, length=32, hex=data.hex(), result=result, sequence=seq, control_valid=1, control_timeout=0, deadline_late_ns=0, skipped=0))

    def tearDown(self): self.temp.cleanup()

    def run_analysis(self):
        serial = self.root / 'serial.jsonl'; serial.write_text(''.join(json.dumps(row)+'\n' for row in self.serial))
        events = self.root / 'peer.csv'
        with events.open('w', newline='') as output:
            writer = csv.DictWriter(output, fieldnames=peer.CSV_FIELDS)
            writer.writeheader(); writer.writerows(self.events)
        return analysis.screening(serial, events, 20, self.limits)

    def test_healthy_replay_is_data_only(self):
        result = self.run_analysis()
        self.assertEqual(result['result'], 'SCREEN_DATA_PASS', result)
        self.assertFalse(result['physical_qualification'])

    def test_crc_tamper_despite_claimed_valid(self):
        self.events[2000]['hex'] = '00' * 32
        self.assertEqual(self.run_analysis()['result'], 'FAIL')

    def test_duplicate_sequence_despite_claimed_in_order(self):
        self.events[2000]['hex'] = self.events[1998]['hex']
        self.events[2000]['sequence'] = self.events[1998]['sequence']
        self.assertEqual(self.run_analysis()['result'], 'FAIL')

    def test_short_peer_data_cannot_pass(self):
        self.events = self.events[1000:1200]
        self.assertEqual(self.run_analysis()['result'], 'INCOMPLETE')

    def test_missing_telemetry(self):
        self.serial = [e for e in self.serial if not e['line'].startswith('LCD_')]
        self.assertEqual(self.run_analysis()['result'], 'INCOMPLETE')

    def test_sparse_runtime_cannot_pass(self):
        self.serial = [e for e in self.serial if not e['line'].startswith('TRANSPORT_') or e['elapsed_ns'] in (10_000_000_000, 71_000_000_000)]
        self.assertEqual(self.run_analysis()['result'], 'INCOMPLETE')

    def test_lateness_and_loss(self):
        self.events[2001]['deadline_late_ns'] = 101_000_000
        self.assertEqual(self.run_analysis()['result'], 'FAIL')

    def test_draft_limits_refused(self):
        self.limits['decision'] = 'pending'
        with self.assertRaises(ValueError): self.run_analysis()


if __name__ == '__main__': unittest.main()
