#!/usr/bin/env python3
"""Opt-in real Codex/Claude/Pi/OpenCode -> native ingestion -> two authenticated SSH clients.

Only newly created synthetic sessions are prompted/resumed. This is a native
wire/live-provider gate, not a UI-paint or physical-device performance claim.
Private transcripts/authentication are never included in the result report.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


HERE = Path(__file__).resolve().parent
owned = module('owned', HERE / 'owned-process.py')
ssh_fixture = module('mac_ssh', HERE / 'mac-agent-ssh-fixture.py')
capture = module('provider_capture', HERE.parent / 'performance/agent-center/deepseek_provider_smoke.py')


class Client:
    def __init__(self, command, log):
        self.error_path = Path(log.name).with_suffix('.protocol-error.json')
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            self.send(dict(kind='hello', v=3, id='hello'))
            self.hello = self.receive()
            if self.hello.get('kind') != 'hello':
                raise RuntimeError('native_handshake_failed')
        except BaseException:
            self.close()
            raise
        self.head = None
        self.version = 0

    def send(self, value):
        data = json.dumps(value).encode()
        self.process.stdin.write(struct.pack('!I', len(data)) + data)
        self.process.stdin.flush()

    def receive(self, timeout=10):
        def exact(count):
            data = bytearray()
            deadline = time.monotonic() + timeout
            while len(data) < count:
                if not select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    raise TimeoutError('native_frame_timeout')
                part = os.read(self.process.stdout.fileno(), count - len(data))
                if not part:
                    raise EOFError('native_frame_eof')
                data.extend(part)
            return data
        size, = struct.unpack('!I', exact(4))
        if not 0 < size <= 65536:
            raise RuntimeError('native_frame_limit')
        value = json.loads(exact(size))
        if value.get('kind') == 'error':
            self.error_path.write_text(json.dumps(value))
            raise RuntimeError('native_protocol_rejected')
        return value

    def bootstrap(self, provider, path):
        reference = dict(nativeSessionID=str(path)) if provider == 'opencode' else dict(transcriptRef=str(path))
        self.send(dict(kind='resolve', id='resolve', provider=provider, **reference))
        response = self.receive()
        if response.get('kind') != 'resolved':
            raise RuntimeError('resolve_failed')
        self.thread = response['thread']
        self.send(dict(kind='window.read', id='bootstrap_' + uuid.uuid4().hex, thread=self.thread, operation='bootstrap', windowVersion=0))
        page = CommittedPage(self)
        while True:
            value = self.receive()
            rows = page.accept(value)
            if rows is not None:
                return rows

    def ack(self, end):
        self.head = end['window'].get('segmentID', self.head)
        self.version = end['window']['version']
        self.send(dict(kind='window.ack', id='ack_' + end['id'], thread=self.thread,
            transaction=end['id'], windowVersion=self.version, viewport=[self.head], head=self.head))

    def subscribe(self):
        self.send(dict(kind='subscribe', id='watch', thread=self.thread, interest='fast',
            windowVersion=self.version, liveCursor=self.cursor))
        if self.receive()['kind'] != 'subscribed':
            raise RuntimeError('subscribe_failed')

    def close(self):
        with owned.cleanup_signals():
            self._close()

    def _close(self):
        try:
            self.process.stdin.close()
            self.process.stdout.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=3)


class CommittedPage:
    """Delivery is evidence only after a complete, matching, acknowledged page."""
    def __init__(self, client):
        self.client = client
        self.transaction = None
        self.rows = []
        self.end = None

    def accept(self, value):
        kind = value['kind']
        if kind == 'page.begin':
            if self.transaction is not None:
                raise RuntimeError('overlapping_native_page')
            self.transaction = value['id']
            self.rows = []
            self.end = None
        elif kind in ('page.record', 'page.end'):
            if self.transaction is None or value['id'] != self.transaction or self.end is not None:
                raise RuntimeError('unmatched_native_page')
            if kind == 'page.record':
                check_rows([value])
                self.rows.append(value)
                if len(self.rows) > 100:
                    raise RuntimeError('native_page_limit')
            else:
                if value.get('records') != len(self.rows):
                    raise RuntimeError('native_page_count_mismatch')
                self.end = value
                self.client.ack(value)
        elif kind == 'window.acked':
            if (self.end is None or value.get('id') != 'ack_' + self.transaction or
                value.get('windowVersion') != self.end['window']['version'] or
                value.get('liveCursor') != self.end.get('liveCursor')):
                raise RuntimeError('unmatched_native_ack')
            self.client.cursor = value['liveCursor']
            rows = self.rows
            self.transaction = self.end = None
            self.rows = []
            return rows
        return None


def assistant_marker(rows, marker):
    return any(row.get('record', {}).get('role') == 'assistant' and
        marker.casefold() in json.dumps(row['record'], ensure_ascii=False).casefold() for row in rows)


def successful_provider_events(data):
    events = [json.loads(line) for line in data.splitlines() if line.strip()]
    if any(event.get('type') == 'result' and event.get('is_error') is True for event in events):
        raise RuntimeError('provider_reported_error')
    if any(event.get('type') == 'error' or (event.get('type') == 'message_end' and
           event.get('message', {}).get('stopReason') in ('error', 'aborted')) for event in events):
        raise RuntimeError('provider_reported_error')
    return events


def check_rows(rows):
    for row in rows:
        record = row.get('record', {})
        if (row.get('disposition') in ('unsupported', 'unclassified', 'malformed') or
            record.get('type') in ('unsupported', 'unknown', 'malformed') or
            record.get('unparsedContentCount', 0) != 0 or any(
            block.get('type') in ('unknown', 'unsupported', 'malformed') for block in record.get('blocks', []))):
            raise RuntimeError('unclassified_native_record')


def run_provider(args, root, provider, auth_home):
    case = root / provider
    case.mkdir()
    first = case / 'first'; first.mkdir()
    second = case / 'second'; second.mkdir()
    environment = dict(os.environ)
    for name in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'TMUX', 'TMUX_PANE'):
        environment.pop(name, None)
    initial_marker = 'TESSERA_DEDICATED_INITIAL_REPLY'
    live_marker = 'TESSERA_DEDICATED_LIVE_REPLY'
    credential_guard = 'NO_CREDENTIAL_SENTINEL'
    session = str(uuid.uuid4())
    if provider == 'opencode':
        credential_guard = capture.read_deepseek_key(args.env_file)
        environment = {name: os.environ[name] for name in ('PATH','TMPDIR','LANG') if name in os.environ}
        environment.update(HOME=str(case),DEEPSEEK_API_KEY=credential_guard,
            XDG_CONFIG_HOME=str(case/'config'),XDG_DATA_HOME=str(case/'data'),
            XDG_CACHE_HOME=str(case/'cache'),XDG_STATE_HOME=str(case/'state'),
            OPENCODE_CONFIG_CONTENT=json.dumps({'share':'disabled','autoupdate':False,
                'permission':{'*':'deny'},'enabled_providers':['deepseek'],
                'provider':{'deepseek':{'options':{'apiKey':'{env:DEEPSEEK_API_KEY}'}}}}))
        base=[str(args.opencode),'run','--pure','--model','deepseek/deepseek-v4-flash','--format','json']
        initial=base+['--title','Tessera dedicated synthetic ingestion test',
                      'Reply exactly '+initial_marker+'. No tools or file access.']
    elif provider == 'pi':
        credential_guard = capture.read_deepseek_key(args.env_file)
        environment.update(PI_CODING_AGENT_DIR=str(case / 'pi'), DEEPSEEK_API_KEY=credential_guard,
            PI_TELEMETRY='0', PI_OFFLINE='1')
        base = [str(args.pi), '--provider', 'deepseek', '--model', 'deepseek-v4-flash', '--print', '--mode', 'json',
            '--no-tools', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-context-files',
            '--session-dir', str(case / 'pi/sessions/fixture')]
        initial = base + ['Reply exactly ' + initial_marker + '. No tools or file access.']
    elif provider == 'codex':
        environment.update(HOME=str(auth_home.parent), CODEX_HOME=str(auth_home))
        base = [str(args.codex), '--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only',
            '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check', '--json']
        initial = base + ['Reply exactly ' + initial_marker + '. No tools or file access.']
    else:
        initial_marker = 'hello'
        live_marker = 'goodbye'
        environment.update(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1', CLAUDE_CODE_ENABLE_TELEMETRY='0')
        environment.pop('CLAUDE_CONFIG_DIR', None)
        base = [str(args.claude), '--setting-sources', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
            '--disable-slash-commands', '--no-chrome', '--tools', '', '--allowedTools', '', '--effort', 'low',
            '--print', '--verbose', '--output-format', 'stream-json', '--max-budget-usd', '1']
        initial = base + ['--session-id', session, 'Reply with just the word hello.']
    code, guard, data = capture.capture_provider(initial, case, environment, credential_guard, time.monotonic())
    if code != 0 or guard is not None:
        raise RuntimeError('initial_provider_failed')
    events = successful_provider_events(data)
    if provider == 'opencode':
        path=case/'data/opencode/opencode.db'
        with sqlite3.connect(f'file:{path}?mode=ro',uri=True) as database:
            sessions=database.execute('SELECT id FROM session').fetchall()
        if len(sessions)!=1: raise RuntimeError('dedicated_session_not_unique')
        session=sessions[0][0]; paths=[path]
        resume=base+['--session',session,'Reply exactly '+live_marker+'. No tools or file access.']
    elif provider == 'pi':
        paths = list((case / 'pi/sessions').rglob('*.jsonl'))
        if len(paths) != 1: raise RuntimeError('dedicated_transcript_not_unique')
        resume = base + ['--session', str(paths[0]), 'Reply exactly ' + live_marker + '. No tools or file access.']
    elif provider == 'codex':
        session = next(event['thread_id'] for event in events if event.get('type') == 'thread.started')
        paths = list((auth_home / 'sessions').rglob('*' + session + '.jsonl'))
        resume = [str(args.codex), '--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only',
            'resume', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check', '--json', session,
            'Reply exactly ' + live_marker + '. No tools or file access.']
    else:
        paths = list((Path.home() / '.claude/projects').glob('*/' + session + '.jsonl'))
        resume = base + ['--resume', session, 'Reply with just the word goodbye.']
    if len(paths) != 1:
        raise RuntimeError('dedicated_transcript_not_unique')
    path = paths[0]
    if provider != 'opencode': shutil.copyfile(path, case / 'before-live.jsonl')
    source_before = path.stat()
    runtime = case / 'r'
    service_environment = dict(os.environ, CODEX_HOME=str(auth_home), CLAUDE_CONFIG_DIR=str(Path.home() / '.claude'))
    if provider == 'pi': service_environment['PI_CODING_AGENT_DIR'] = str(case / 'pi')
    service_environment['XDG_DATA_HOME'] = str(case/'data')
    clients = []
    logs = []
    service = None
    live = None
    try:
        service_log = (case / 'native-service.log').open('wb'); logs.append(service_log)
        service = owned.OwnedProcess([str(args.host), 'serve', '--runtime', str(runtime), '--idle-ms', '30000'],
            env=service_environment, stdout=subprocess.DEVNULL, stderr=service_log)
        deadline = time.monotonic() + 3
        while not (runtime / 'client.sock').exists():
            if service.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('native_service_start_failed')
            time.sleep(.01)
        command = ['/usr/bin/env', 'CODEX_HOME=' + str(auth_home), 'CLAUDE_CONFIG_DIR=' + str(Path.home() / '.claude'),
            str(args.host), 'connect', '--stdio', '--runtime', str(runtime), '--attach-only']
        if provider == 'pi': command.insert(1, 'PI_CODING_AGENT_DIR=' + str(case / 'pi'))
        command.insert(1,'XDG_DATA_HOME='+str(case/'data'))
        with ssh_fixture.MacSSHFixture(command) as fixture:
            try:
                for index in range(2):
                    log = (case / f'ssh-{index}.log').open('wb'); logs.append(log)
                    client = Client(fixture.command, log); clients.append(client)
                    rows = client.bootstrap(provider, session if provider == 'opencode' else path)
                    check_rows(rows)
                    if not assistant_marker(rows, initial_marker):
                        raise RuntimeError('initial_assistant_not_renderable')
                    client.subscribe()
                if len({client.hello['servicePID'] for client in clients}) != 1 or len({client.hello['serviceEpoch'] for client in clients}) != 1:
                    raise RuntimeError('ssh_clients_did_not_reuse_service')
                if service.poll() is not None or service.child_pid is None or any(
                    client.hello['servicePID'] != service.child_pid for client in clients):
                    raise RuntimeError('ssh_clients_attached_unowned_service')
                out = (second / 'stdout.jsonl').open('wb'); err = (second / 'stderr.log').open('wb')
                logs += [out, err]
                started = time.monotonic()
                live = owned.OwnedProcess(resume, cwd=case, env=environment, stdout=out, stderr=err)
                seen = {}
                record_counts = [0, 0]
                pages = [CommittedPage(client) for client in clients]
                resync_counts = [0, 0]
                heartbeat = started
                provider_complete = False
                while len(seen) != 2 or live.poll() is None:
                    if time.monotonic() - started > 60:
                        raise TimeoutError('live_provider_delivery_timeout')
                    if sum((second / name).stat().st_size for name in ('stdout.jsonl', 'stderr.log')) > capture.OUTPUT_LIMIT:
                        raise RuntimeError('live_provider_output_limit')
                    if not provider_complete and live.poll() is not None:
                        successful_provider_events(capture.read_private_logs(second, credential_guard))
                        provider_complete = True
                    if time.monotonic() - heartbeat >= 10:
                        for client in clients:
                            client.send(dict(kind='heartbeat', id='beat_' + uuid.uuid4().hex))
                        heartbeat = time.monotonic()
                    ready, _, _ = select.select([client.process.stdout for client in clients], [], [], .1)
                    for index, client in enumerate(clients):
                        if client.process.stdout not in ready:
                            continue
                        value = client.receive()
                        if value['kind'] == 'resyncRequired':
                            # Claude touches the file on resume before adding
                            # bytes. The production protocol intentionally
                            # invalidates a same-size mutation, then bootstraps
                            # a new generation. Exercise that contract rather
                            # than killing the provider at the first resync.
                            if value.get('code') != 'sourceChanged' or resync_counts[index] >= 3:
                                client.error_path.write_text(json.dumps(value))
                                raise RuntimeError('unexpected_or_repeated_resync')
                            resync_counts[index] += 1
                            pages[index] = CommittedPage(client)
                            rows = client.bootstrap(provider, session if provider == 'opencode' else path)
                            check_rows(rows)
                            if assistant_marker(rows, live_marker):
                                seen.setdefault(index, round((time.monotonic() - started) * 1000, 3))
                            client.subscribe()
                        else:
                            rows = pages[index].accept(value)
                            if rows is not None:
                                record_counts[index] += len(rows)
                                if assistant_marker(rows, live_marker):
                                    seen.setdefault(index, round((time.monotonic() - started) * 1000, 3))
                if live.returncode != 0:
                    raise RuntimeError('live_provider_failed')
                # Completion may have become visible in the loop condition.
                # Validate the final event even when the loop body did not run.
                successful_provider_events(capture.read_private_logs(second, credential_guard))
                return dict(provider=provider, initial_assistant_renderable=True, authenticated_ssh_clients=2,
                    shared_service=True, owned_service_verified=True,
                    live_assistant_committed_to_both=True, live_records=record_counts,
                    unknown_or_unparsed_records=0,
                    source_changed_recoveries=resync_counts,
                    provider_start_to_live_assistant_ms=[seen[index] for index in range(2)])
            finally:
                with owned.cleanup_signals():
                    failures = []
                    for client in clients:
                        try: client.close()
                        except Exception: failures.append('ssh_client_cleanup')
                    if failures: raise RuntimeError('ssh_client_cleanup_failed')
    finally:
        try:
            if live:
                try: live.close()
                finally: capture.read_private_logs(second, credential_guard)
        finally:
            try:
                if service: service.close()
            finally:
                for log in logs: log.close()
                if provider != 'opencode': shutil.copyfile(path, case / 'after-live.jsonl')
                source_after = path.stat()
                (case / 'source-change.json').write_text(json.dumps(dict(same_inode=source_before.st_ino == source_after.st_ino,
                    before_bytes=source_before.st_size, after_bytes=source_after.st_size)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--codex', type=Path, default=Path('/opt/homebrew/bin/codex'))
    parser.add_argument('--claude', type=Path, default=Path.home() / '.local/bin/claude')
    parser.add_argument('--pi', type=Path, default=Path('/opt/homebrew/bin/pi'))
    parser.add_argument('--opencode', type=Path, default=Path.home() / '.opencode/bin/opencode')
    parser.add_argument('--env-file', type=Path)
    parser.add_argument('--providers', nargs='+', choices=['codex', 'claude', 'pi', 'opencode'], default=['codex', 'claude'])
    args = parser.parse_args()
    if os.environ.get('TESSERA_RUN_MAC_AGENT_LIVE') != '1':
        parser.error('explicit credentialed Mac test opt-in required')
    if set(args.providers) & {'pi','opencode'} and args.env_file is None: parser.error('Pi/OpenCode require the explicitly supplied DeepSeek dotenv file')
    args.host = args.host.resolve(strict=True)
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='tml-', dir='/private/tmp'))
    auth_home = root / 'home/.codex'; auth_home.mkdir(parents=True)
    auth = auth_home / 'auth.json'
    print(json.dumps({'private_artifacts': str(root)}), flush=True)
    results = []
    try:
        if 'codex' in args.providers:
            shutil.copyfile(Path.home() / '.codex/auth.json', auth)
        for provider in args.providers:
            result = run_provider(args, root, provider, auth_home)
            results.append(result)
            print(json.dumps(result), flush=True)
    finally:
        with owned.cleanup_signals():
            auth.unlink(missing_ok=True)
            (root / 'content-free-results.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    with owned.termination_cleanup():
        main()
