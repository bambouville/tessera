#!/usr/bin/env python3
"""Opt-in synthetic OpenCode/Pi credential smoke; not an ingestion acceptance gate.

Only DEEPSEEK_API_KEY is read from the explicitly supplied dotenv file. Never
sources shell, prints a key, or resumes a user session. Configuration uses an
environment placeholder. Bounded logs are checked for accidental key output;
detected-secret and oversized logs are deleted, not retained as evidence.
Provider configuration and transcripts live in a new private run directory.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import tempfile
import time
import importlib.util

_spec = importlib.util.spec_from_file_location('owned_process', Path(__file__).resolve().parents[2] / 'integration/owned-process.py')
_owned = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_owned)
OUTPUT_LIMIT = 4 * 1024 * 1024
EVENT_TYPES = frozenset(('session', 'agent_start', 'turn_start', 'message_start', 'message_end',
    'message_update', 'turn_end', 'agent_end', 'agent_settled', 'step_start', 'text', 'step_finish', 'error'))


def read_deepseek_key(path):
    matches = re.findall(r'^DEEPSEEK_API_KEY\s*=\s*([^\r\n]+)$', path.read_text(), re.M)
    if len(matches) != 1: raise ValueError('exactly one DEEPSEEK_API_KEY assignment required')
    key = matches[0].strip().strip('\"\'')
    if not re.fullmatch(r'[A-Za-z0-9_-]{16,256}', key): raise ValueError('unsupported dotenv key syntax')
    return key


def read_private_logs(directory, key):
    paths = [directory / name for name in ('stdout.jsonl', 'stderr.log')]
    data = []
    failure = None
    for path in paths:
        try:
            with path.open('rb') as stream:
                content = stream.read(OUTPUT_LIMIT + 1)
        except OSError:
            failure = failure or 'output_read_failed'
            continue
        data.append(content)
        if len(content) > OUTPUT_LIMIT or sum(map(len, data)) > OUTPUT_LIMIT:
            failure = 'output_limit'
        if key.encode() in content:
            failure = 'credential_in_output'
        # JSON escaping must not bypass credential detection. Provider logs
        # may mix JSON and plain text, so only decode complete valid lines.
        for line in content.splitlines():
            try:
                if key in json.dumps(json.loads(line), ensure_ascii=False):
                    failure = 'credential_in_output'
            except (ValueError, UnicodeError):
                pass
    if failure:
        errors = []
        for path in paths:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                errors.append(path.name)
        (directory / 'output-guard.json').write_text(json.dumps({'guard': failure, 'cleanup_failures': errors}))
        raise RuntimeError('provider output rejected; see content-free output-guard.json')
    return data[0]


def event_counts(events):
    return dict(collections.Counter(event.get('type') if event.get('type') in EVENT_TYPES else '<unknown>' for event in events))


def assistant_texts(provider, events):
    texts = []
    for event in events:
        if event.get('type') == 'error':
            raise RuntimeError('provider_reported_error')
        if provider == 'pi' and event.get('type') == 'message_end' and event.get('message', {}).get('role') == 'assistant':
            message = event['message']
            if message.get('stopReason') in ('error', 'aborted') or message.get('errorMessage'):
                raise RuntimeError('provider_reported_error')
            texts.extend(block.get('text', '') for block in message.get('content', []) if block.get('type') == 'text')
        if provider == 'opencode' and event.get('type') == 'text':
            texts.append(event.get('part', {}).get('text', ''))
    return texts


def capture_provider(command, directory, environment, key, started):
    with (directory / 'stdout.jsonl').open('wb') as out, (directory / 'stderr.log').open('wb') as err:
        process = _owned.OwnedProcess(command, cwd=directory, env=environment, stdout=out, stderr=err)
        stopped = None
        try:
            while process.poll() is None:
                if time.monotonic() - started > 90:
                    stopped = 'timeout'; break
                if sum((directory / name).stat().st_size for name in ('stdout.jsonl', 'stderr.log')) > OUTPUT_LIMIT:
                    stopped = 'output_limit'; break
                time.sleep(.05)
        finally:
            with _owned.cleanup_signals():
                try:
                    process.close()
                finally:
                    # Also inspect/remove logs on signal or provider failure.
                    data = read_private_logs(directory, key)
    return process.returncode, stopped, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, required=True)
    parser.add_argument('--pi', type=Path, required=True)
    parser.add_argument('--opencode', type=Path, required=True)
    parser.add_argument('--providers', nargs='+', choices=['pi', 'opencode'], default=['pi', 'opencode'])
    args = parser.parse_args()
    if os.environ.get('TESSERA_RUN_DEEPSEEK_PROBE') != '1':
        parser.error('explicit synthetic provider request opt-in required')
    try: key = read_deepseek_key(args.env_file)
    except ValueError as error: parser.error(str(error))
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='tessera-deepseek-live-', dir='/private/tmp'))
    print(json.dumps({'private_artifacts': str(root)}), flush=True)
    results = []
    for provider, binary in [('pi', args.pi.resolve(strict=True)), ('opencode', args.opencode.resolve(strict=True))]:
        if provider not in args.providers: continue
        directory = root / provider
        directory.mkdir(mode=0o700)
        environment = {name: os.environ[name] for name in ('PATH', 'TMPDIR', 'LANG') if name in os.environ}
        environment.update(HOME=str(directory), DEEPSEEK_API_KEY=key,
            XDG_CONFIG_HOME=str(directory / 'config'), XDG_DATA_HOME=str(directory / 'data'),
            XDG_CACHE_HOME=str(directory / 'cache'), XDG_STATE_HOME=str(directory / 'state'),
            PI_CODING_AGENT_DIR=str(directory / 'pi'), PI_TELEMETRY='0', PI_OFFLINE='1',
            OPENCODE_CONFIG_CONTENT=json.dumps({'share': 'disabled', 'autoupdate': False,
                'permission': {'*': 'deny'}, 'enabled_providers': ['deepseek'],
                'provider': {'deepseek': {'options': {'apiKey': '{env:DEEPSEEK_API_KEY}'}}}}))
        marker = f'TESSERA_{provider.upper()}_DEEPSEEK_OK'
        prompt = f'Reply exactly {marker}. Do not use tools or inspect files.'
        command = ([str(binary), '--provider', 'deepseek', '--model', 'deepseek-v4-flash', '--print', '--mode', 'json',
            '--no-tools', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes',
            '--no-context-files', '--session-dir', str(directory / 'sessions'), prompt]
            if provider == 'pi' else [str(binary), '--print-logs', '--log-level', 'DEBUG', 'run', '--pure', '--model', 'deepseek/deepseek-v4-flash',
                '--format', 'json', '--title', 'Tessera dedicated synthetic ingestion test', prompt])
        started = time.monotonic()
        exit_code, stopped, data = capture_provider(command, directory, environment, key, started)
        events = [json.loads(line) for line in data.splitlines() if line.strip()]
        # Require an assistant text event, not the echoed user prompt.
        texts = assistant_texts(provider, events)
        result = dict(provider=provider, exit_code=exit_code, guard=stopped,
            wall_ms=round((time.monotonic() - started) * 1000, 3), assistant_marker=any(marker in text for text in texts),
            event_types=event_counts(events))
        results.append(result)
        print(json.dumps(result), flush=True)
    (root / 'content-free-results.json').write_text(json.dumps(results, indent=2))
    return 0 if all(row['exit_code'] == 0 and row['guard'] is None and row['assistant_marker'] for row in results) else 1


if __name__ == '__main__':
    with _owned.termination_cleanup():
        raise SystemExit(main())
