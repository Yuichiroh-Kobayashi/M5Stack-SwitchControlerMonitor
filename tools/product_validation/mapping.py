"""Guided observation and explicit operator review of real USB-only mapping."""
import json
import re
from pathlib import Path

BUTTONS = ['A', 'B', 'X', 'Y', 'L', 'R', 'ZL', 'ZR', 'MINUS', 'PLUS', 'HOME', 'CAPTURE', 'LSTICK', 'RSTICK']
DPAD = ['UP', 'UP_RIGHT', 'RIGHT', 'DOWN_RIGHT', 'DOWN', 'DOWN_LEFT', 'LEFT', 'UP_LEFT']
STICKS = ['LX_MIN', 'LX_MAX', 'LY_MIN', 'LY_MAX', 'RX_MIN', 'RX_MAX', 'RY_MIN', 'RY_MAX']
REQUIRED = BUTTONS + ['DP_' + name for name in DPAD] + STICKS
EXPLORATORY = 'BUTTON15'


def parse_fields(line: str) -> dict[str, str]:
    return dict(re.findall(r'(\w+)=([^\s]+)', line))


def load_serial(path: Path) -> list[dict]:
    records = []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        entry = json.loads(line)
        if not isinstance(entry.get('elapsed_ns'), int) or not isinstance(entry.get('line'), str):
            raise ValueError('Serial record requires integer elapsed_ns and line')
        records.append(entry)
    if any(b['elapsed_ns'] < a['elapsed_ns'] for a, b in zip(records, records[1:])):
        raise ValueError('Serial host timestamps moved backwards')
    return records


def sample(entry: dict) -> dict | None:
    if not entry['line'].startswith('USB_INTAKE_INPUT '):
        return None
    fields = parse_fields(entry['line'])
    required = ['RAW', 'VALID', 'BUTTONS', 'DP', 'LX', 'LY', 'RX', 'RY', 'LT', 'RT', 'LEN', 'ID_FLAG', 'COPIED']
    if not all(key in fields for key in required):
        return None
    try:
        raw = bytes.fromhex(fields['RAW'])
        good = fields['VALID'] == '1' and fields['LEN'] == '8' and fields['ID_FLAG'] == '0' and fields['COPIED'] == '8' and len(raw) == 8
        return {'elapsed_ns': entry['elapsed_ns'], 'raw': raw.hex().upper(), 'valid': good,
                'buttons': int(fields['BUTTONS'], 16), 'dpad': int(fields['DP']),
                **{key: int(fields[key]) for key in ['LX', 'LY', 'RX', 'RY', 'LT', 'RT']}}
    except ValueError:
        return None


def neutral(item: dict) -> bool:
    return item['valid'] and item['buttons'] == 0 and item['dpad'] == 8 and item['LT'] == item['RT'] == 0 and all(item[axis] == 128 for axis in ('LX', 'LY', 'RX', 'RY'))


def matches(step: str, item: dict) -> bool:
    if not item['valid']:
        return False
    if step in BUTTONS:
        return item['buttons'] == 1 << BUTTONS.index(step) and item['dpad'] == 8 and all(item[a] == 128 for a in ('LX', 'LY', 'RX', 'RY')) and item['LT'] == (255 if step == 'ZL' else 0) and item['RT'] == (255 if step == 'ZR' else 0)
    if step.startswith('DP_') and step[3:] in DPAD:
        return item['buttons'] == 0 and item['dpad'] == DPAD.index(step[3:]) and all(item[a] == 128 for a in ('LX', 'LY', 'RX', 'RY')) and item['LT'] == item['RT'] == 0
    if step in STICKS:
        axis, direction = step.split('_')
        # Full endpoint is recorded, not inferred from a small directional move.
        return item['buttons'] == 0 and item['dpad'] == 8 and item['LT'] == item['RT'] == 0 and all(item[a] == 128 for a in ('LX', 'LY', 'RX', 'RY') if a != axis) and item[axis] == (0 if direction == 'MIN' else 255)
    if step == EXPLORATORY:
        return bool(bytes.fromhex(item['raw'])[2] & 0x80)
    raise ValueError('Unknown mapping step')


def analyze_step(path: Path, step: str, metadata: dict) -> dict:
    if step not in REQUIRED + [EXPLORATORY]:
        raise ValueError('Unknown mapping step')
    entries = load_serial(path)
    samples = [s for e in entries if (s := sample(e)) is not None]
    # Runner prompts: neutral 0..4s; hold 4..10s; release 10..16s.
    # Ignore prompt transition windows and require multiple 1Hz records.
    before = [s for s in samples if 1_000_000_000 <= s['elapsed_ns'] < 4_000_000_000]
    active = [s for s in samples if 6_000_000_000 <= s['elapsed_ns'] < 10_000_000_000]
    released = [s for s in samples if 12_000_000_000 <= s['elapsed_ns'] < 16_000_000_000]
    checks = {'neutral_before': len(before) >= 2 and all(neutral(s) for s in before),
              'no_malformed_input': len(samples) == sum(e['line'].startswith('USB_INTAKE_INPUT ') for e in entries),
              'target_held': len(active) >= 2 and all(matches(step, s) for s in active),
              'neutral_after': len(released) >= 2 and all(neutral(s) for s in released),
              'no_invalid_samples': bool(samples) and all(s['valid'] for s in samples)}
    return {'schema': 'core-mapping-step-v1', 'step': step,
            'result': 'OBSERVED_MATCH' if all(checks.values()) else 'INCOMPLETE_OR_MISMATCH',
            'human_confirmed': False, 'checks': checks, 'samples': samples,
            'controller_profile_sha256': metadata.get('controller_profile_sha256'),
            'source_manifest_sha256': metadata.get('source_manifest_sha256'),
            'expected_pnp_id': metadata.get('expected_pnp_id'),
            'trial_kind': metadata.get('trial_kind'), 'binary_sha256': metadata.get('binary_sha256'),
            'note': 'Requires operator confirmation of physical labels, range/direction, UI and turbo/macro state.'}


def make_review(paths: list[Path], operator: str, disposition: str, confirmed: bool) -> dict:
    steps = [json.loads(path.read_text(encoding='utf-8-sig')) for path in paths]
    if not operator.strip() or not disposition.strip() or not confirmed:
        raise ValueError('Explicit operator, Button15 disposition and all human checks required')
    by_name = {step['step']: step for step in steps}
    if len(by_name) != len(steps) or not all(name in by_name for name in REQUIRED):
        raise ValueError('Every required step must be supplied once')
    required = [by_name[name] for name in REQUIRED]
    if any(s.get('schema') != 'core-mapping-step-v1' or s.get('result') != 'OBSERVED_MATCH' or s.get('trial_kind') != 'physical_usb_mapping' for s in required):
        raise ValueError('Missing physical mapping observations')
    profiles = {s.get('controller_profile_sha256') for s in required}
    identities = {s.get('expected_pnp_id') for s in required}
    manifests = {s.get('source_manifest_sha256') for s in required}
    if len(manifests) != 1 or not all(isinstance(s, str) and re.fullmatch(r'[0-9A-Fa-f]{64}', s) for s in manifests):
        raise ValueError('Missing or different candidate source manifests')
    if len(profiles) != 1 or len(identities) != 1 or None in profiles or None in identities:
        raise ValueError('Mapping observations use different or missing identities/profiles')
    return {'schema': 'core-mapping-review-v1', 'result': 'PASS', 'operator': operator,
            'human_confirmed': True, 'required_steps': REQUIRED, 'button15_disposition': disposition,
            'controller_profile_sha256': profiles.pop(), 'expected_pnp_id': identities.pop(),
            'source_manifest_sha256': manifests.pop(),
            'observation_reports': [str(path.resolve()) for path in paths]}


def validate_review(path: Path, profile: str, identity: str, source_manifest: str) -> dict:
    review = json.loads(path.read_text(encoding='utf-8-sig'))
    if review.get('schema') != 'core-mapping-review-v1' or review.get('result') != 'PASS' or review.get('human_confirmed') is not True or not review.get('operator') or not review.get('button15_disposition'):
        raise ValueError('Manual USB mapping review is not complete')
    if set(review.get('required_steps', [])) != set(REQUIRED) or review.get('controller_profile_sha256') != profile or review.get('expected_pnp_id') != identity or review.get('source_manifest_sha256') != source_manifest:
        raise ValueError('Manual mapping review does not match this candidate/device')
    # Re-read the observations so a summary alone cannot silently bypass steps.
    rebuilt = make_review([Path(p) for p in review.get('observation_reports', [])], review['operator'], review['button15_disposition'], True)
    if rebuilt['controller_profile_sha256'] != profile or rebuilt['expected_pnp_id'] != identity or rebuilt['source_manifest_sha256'] != source_manifest:
        raise ValueError('Mapping observation identity mismatch')
    return review


def instructions() -> dict:
    return {'required_steps': REQUIRED, 'exploratory_step': EXPLORATORY,
            'phases_seconds': {'neutral': [0, 4], 'hold': [4, 10], 'release': [10, 16]},
            'instructions': 'Run one step at a time. Start neutral, hold only the named control at HOLD, then release at RELEASE. For axis steps reach the named endpoint. Inspect UI and physical direction separately.',
            'limits': 'Exact128 neutral and 0/255 endpoints are observation criteria. If hardware differs, retain mismatch evidence and review; do not silently widen thresholds.'}
