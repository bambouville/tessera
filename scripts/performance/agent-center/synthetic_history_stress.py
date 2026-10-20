#!/usr/bin/env python3
"""Synthetic native production-window stress; no provider or private sessions."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tools/AgentHost/tests'))
from synthetic_history import History, WindowClient, install_termination_handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--counts', type=int, nargs='+', default=[19999, 20000, 20001, 100000, 1000000])
    parser.add_argument('--providers', nargs='+', choices=['claude', 'codex', 'pi', 'kimi'], default=['claude', 'codex', 'pi', 'kimi'])
    parser.add_argument('--shape', choices=['linear', 'branches', 'revisions', 'undo', 'lineage'], default='linear')
    parser.add_argument('--padding', type=int, default=0, help='0..8192 extra displayed body bytes per record')
    parser.add_argument('--opaque-bytes', type=int, default=0, help='Ignored JSON string bytes per non-header row, streamed in64KiB chunks; supports opt-in multi-GB sources')
    parser.add_argument('--traverse', action='store_true', help='Traverse entire history backward and forward with at most4 retained pages')
    parser.add_argument('--rewrite', action='store_true', help='Warm interior same-inode rewrite plus append, then full traversal (Claude/Codex linear)')
    parser.add_argument('--reconnect', action='store_true', help='Replace the client after initial pages and bootstrap again')
    parser.add_argument('--interrupt', action='store_true', help='Disconnect during a new read, reconnect, then bootstrap again')
    parser.add_argument('--timeout', type=float, default=600, help='Per-case helper deadline, excluding fixture generation')
    parser.add_argument('--rss-mib', type=int, default=256)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('choose a new evidence directory outside Git')
    binary = args.binary.resolve(strict=True)
    if args.timeout <= 0 or args.rss_mib <= 0 or not 0 <= args.padding <= 8192 or args.opaque_bytes < 0 or min(args.counts) < 300:
        parser.error('positive budgets and counts >=300 required')
    output.mkdir(mode=0o700, parents=True)
    report = dict(stage='synthetic_native_window_protocol_not_mobile_or_transport',
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  harness_sha256=hashlib.sha256((ROOT / 'Tools/AgentHost/tests/synthetic_history.py').read_bytes()).hexdigest(),
                  cases=[], passed=False)
    for provider in args.providers:
        for count in args.counts:
            row = dict(provider=provider, shape=args.shape, authored_messages=count,
                       padding_bytes=args.padding, opaque_bytes=args.opaque_bytes)
            client = None
            try:
                with tempfile.TemporaryDirectory(prefix='tessera-history-', dir='/tmp') as directory:
                    history = History(Path(directory), provider, count, args.shape, args.padding, args.opaque_bytes).generate()
                    row.update(physical_source_records=history.physical_records, selected_records=history.selected_records,
                               source_bytes=history.source_bytes)
                    with WindowClient(binary, history, args.timeout, args.rss_mib * 1024 * 1024) as client:
                        row.update(client.exercise(args.traverse, args.rewrite, args.reconnect, args.interrupt))
                    row.update(final_physical_source_records=history.physical_records,
                               final_selected_records=history.selected_records,
                               final_source_bytes=history.source_bytes)
                    row['passed'] = True
            except Exception as error:
                row.update(passed=False, error=str(error), error_type=type(error).__name__)
                if client is not None:
                    row.update(completed_pages=client.page_count, bytes_read=client.bytes_read,
                               sampled_helper_peak_rss_bytes=client.sampled_peak,
                               host_peak_rss_bytes=client.host_peak, rss_samples=client.rss_samples)
            report['cases'].append(row)
            print(json.dumps(row), flush=True)
            (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    report['passed'] = all(row['passed'] for row in report['cases'])
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    install_termination_handler()
    raise SystemExit(main())
