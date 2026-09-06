#!/usr/bin/env python3
"""Product trial CLI. All commands except explicit `peer` are offline."""
import argparse
import json
from pathlib import Path

from product_validation import analysis, evidence, mapping, peer


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    command = sub.add_parser('peer', help='Physical UDP peer: requires completed mapping and frozen limits')
    command.add_argument('--request', required=True)
    command = sub.add_parser('passive')
    command.add_argument('--serial', required=True)
    command = sub.add_parser('analyze')
    command.add_argument('--serial', required=True)
    command.add_argument('--peer', required=True)
    command.add_argument('--limits', required=True)
    command.add_argument('--period-ms', type=int, choices=[10, 20], required=True)
    command.add_argument('--warmup-seconds', type=float, default=10)
    command = sub.add_parser('mapping-plan')
    command = sub.add_parser('mapping-step')
    command.add_argument('--serial', required=True)
    command.add_argument('--metadata', required=True)
    command.add_argument('--step', choices=mapping.REQUIRED + [mapping.EXPLORATORY], required=True)
    command = sub.add_parser('mapping-review')
    command.add_argument('--observations', nargs='+', required=True)
    command.add_argument('--operator', required=True)
    command.add_argument('--button15-disposition', required=True)
    command.add_argument('--confirm-physical-labels-ranges-ui-turbo', action='store_true')
    command = sub.add_parser('validate-gate')
    command.add_argument('--review', required=True)
    command.add_argument('--profile-sha256', required=True)
    command.add_argument('--pnp-id', required=True)
    command.add_argument('--source-manifest-sha256', required=True)
    command.add_argument('--limits', required=True)
    for name in ('finalize', 'verify'):
        command = sub.add_parser(name)
        command.add_argument('--root', required=True)
    parser.add_argument('--output', help='Write JSON to a new output file (never overwrite evidence)')
    args = parser.parse_args()
    if args.output and Path(args.output).exists():
        parser.error('Output file already exists')
    if args.command == 'peer':
        result = peer.run_peer(read(args.request))
    elif args.command == 'passive':
        result = analysis.passive(Path(args.serial))
    elif args.command == 'analyze':
        result = analysis.screening(Path(args.serial), Path(args.peer), args.period_ms, read(args.limits), args.warmup_seconds)
    elif args.command == 'mapping-plan':
        result = mapping.instructions()
    elif args.command == 'mapping-step':
        result = mapping.analyze_step(Path(args.serial), args.step, read(args.metadata))
    elif args.command == 'mapping-review':
        result = mapping.make_review([Path(p) for p in args.observations], args.operator, args.button15_disposition, args.confirm_physical_labels_ranges_ui_turbo)
    elif args.command == 'validate-gate':
        mapping.validate_review(Path(args.review), args.profile_sha256, args.pnp_id, args.source_manifest_sha256)
        analysis.validate_limits(read(args.limits))
        result = {'result': 'MANUAL_GATE_AND_TIMING_CONTRACT_VALID'}
    elif args.command == 'finalize':
        result = evidence.finalize(Path(args.root))
    else:
        evidence.verify(evidence.trial_path(Path(args.root)))
        result = {'result': 'EVIDENCE_HASHES_VALID'}
    text = json.dumps(result, indent=2, ensure_ascii=False) + '\n'
    if args.output:
        with Path(args.output).open('x', encoding='utf-8') as output:
            output.write(text)
    print(text, end='')
    return 1 if result.get('result') in ('FAIL', 'INCOMPLETE', 'INCOMPLETE_OR_MISMATCH') else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as exc:
        raise SystemExit(f'TRIAL_REFUSED: {exc}')
