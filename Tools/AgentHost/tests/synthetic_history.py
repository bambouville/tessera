"""Streaming public fixtures and a bounded production-window acceptance client.

No provider process, credentials, private transcript, or remote host is used.
Expected selection is a formula, not another implementation of the reducers.
"""
from collections import deque
from dataclasses import dataclass
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import threading
import time


SESSION = '00000000-0000-0000-0000-000000000001'


def install_termination_handler():
    # Let the context managers close the owned helper and fixture if a CTest
    # deadline or external supervisor terminates this Python runner.
    def terminate(_number, _frame):
        raise KeyboardInterrupt('synthetic history run terminated')
    signal.signal(signal.SIGTERM, terminate)


@dataclass
class History:
    root: Path
    provider: str
    count: int
    shape: str = 'linear'
    padding: int = 0
    opaque_bytes: int = 0
    physical_records: int = 0
    revision: int | None = None
    rewritten: int | None = None
    skipped: tuple[int, int] | None = None
    revised_into: int | None = None
    # Codex lineage fixtures: where a repeated-ordinal settings row sits relative
    # to each fork cutoff: 'middle' or 'last' inside the inherited prefix, 'child'
    # right after the child's own session_meta, or 'after' past the cutoff (a
    # control: the parent's tail is never parsed for the child, so the row must
    # stay invisible rather than be tolerated). None omits it.
    settings_placement: str | None = None

    def __post_init__(self):
        self.root = self.root.resolve()
        if self.count < 2 or not 0 <= self.padding <= 8192 or self.opaque_bytes < 0:
            raise ValueError('invalid fixture size')
        supported = {'claude': {'linear', 'branches', 'revisions'},
                     'codex': {'linear', 'revisions', 'lineage', 'settings'},
                     'pi': {'linear', 'branches'}, 'kimi': {'linear', 'undo'}}
        if self.shape not in supported.get(self.provider, set()):
            raise ValueError('unsupported fixture shape')
        if self.settings_placement not in (None, 'middle', 'last', 'after', 'child') or \
                (self.settings_placement and (self.provider, self.shape) != ('codex', 'lineage')):
            raise ValueError('settings placement requires a Codex lineage fixture')
        relative = {'claude': 'projects/project/synthetic.jsonl',
                    'codex': f'sessions/rollout-{SESSION}.jsonl',
                    'pi': 'sessions/--synthetic--/timestamp_synthetic-session.jsonl',
                    'kimi': 'sessions/work/session_synthetic/agents/main/wire.jsonl'}
        self.path = self.root / self.provider / relative[self.provider]

    @property
    def source_bytes(self):
        paths = self.path.parent.glob('rollout-*.jsonl') if self.shape == 'lineage' else (self.path,)
        return sum(path.stat().st_size for path in paths)

    @property
    def selected_messages(self):
        count = self.count - self.count // 2 if self.shape == 'undo' else self.count
        return count - (self.skipped[1] - self.skipped[0] if self.skipped else 0)

    @property
    def selected_records(self):
        return self.selected_messages + (self.provider in {'pi', 'kimi'}) + (self.shape == 'undo')

    def text(self, index):
        prefix = 'rewritten' if index == self.rewritten else 'synthetic'
        text = f'{prefix} {index:09d}' + 'x' * self.padding
        return text + (' revised' if index == self.revision else '')

    @staticmethod
    def settings_row(ordinal, thread=SESSION):
        # Codex rollouts can carry thread_settings_applied with the preceding
        # row's ordinal (observed in cli 0.153 rollouts); later rows continue
        # from that value. The settings shape is codex-cli 0.156's.
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='thread_settings_applied', thread_id=thread,
            thread_settings=dict(model='gpt-5', model_provider_id='openai', service_tier='default', approval_policy='on-request',
                                 approvals_reviewer='user', permission_profile=dict(type='workspace-write'),
                                 active_permission_profile=dict(id='default'), cwd='/synthetic', reasoning_effort='high',
                                 collaboration_mode=dict(mode='default', settings=dict()),
                                 runtime_workspace_roots=['/synthetic'], disabled_plugin_ids=[])))

    def message(self, index, ordinal=None):
        identity = f'r{index}'
        if self.provider == 'claude':
            return dict(type='user', uuid=identity, parentUuid=f'r{index-1}' if index else None,
                        message=dict(role='user', content=self.text(index)))
        if self.provider == 'pi':
            return dict(type='message', id=identity, parentId=f'r{index-1}' if index else None,
                        message=dict(role='user', content=self.text(index)))
        if self.provider == 'kimi':
            return dict(type='context.append_message', agentId='main', message=dict(id=identity,
                        role='user', content=[dict(type='text', text=self.text(index))], toolCalls=[]))
        return dict(ordinal=index + 1 if ordinal is None else ordinal, type='event_msg', payload=dict(
            type='item_completed', thread_id=SESSION, turn_id='turn', item=dict(
                type='AgentMessage', id=identity, content=[dict(type='Text', text=self.text(index))])))

    def emit(self, stream, row):
        encoded = json.dumps(row, separators=(',', ':')).encode()
        if self.opaque_bytes and row['type'] not in {'session', 'session_meta', 'metadata'}:
            stream.write(encoded[:-1] + b',"syntheticPadding":"')
            remaining = self.opaque_bytes
            while remaining:
                count = min(65536, remaining); stream.write(b'x' * count); remaining -= count
            stream.write(b'"}\n')
        else:
            stream.write(encoded + b'\n')
        self.physical_records += 1

    def generate(self):
        minimum_bytes = self.count * (self.padding + self.opaque_bytes) * (2 if self.shape == 'branches' else 1)
        if minimum_bytes + 64 * 1024 * 1024 > shutil.disk_usage(self.root).free:
            raise OSError('insufficient temporary disk space for synthetic payload')
        self.path.parent.mkdir(parents=True)
        if self.shape == 'lineage':
            return self.generate_lineage()
        if self.provider == 'kimi':
            directory = self.path.parents[2]
            index = self.root / 'kimi/session_index.jsonl'
            index.write_text(json.dumps(dict(sessionId=directory.name, sessionDir=str(directory), workDir='/synthetic')) + '\n')
            index.chmod(0o600)
        with self.path.open('wb') as stream:
            if self.provider == 'codex':
                self.emit(stream, dict(ordinal=0, type='session_meta', payload=dict(id=SESSION, history_mode='paginated')))
            elif self.provider == 'pi':
                self.emit(stream, dict(type='session', version=3, id='synthetic-session', cwd='/synthetic'))
            elif self.provider == 'kimi':
                self.emit(stream, dict(type='metadata', protocol_version='1.4'))
            for index in range(self.count):
                # Pi selects the last persisted node: put the abandoned branch
                # before the final authored node of the intended chain.
                if self.shape == 'branches' and self.provider == 'pi' and index == self.count - 1:
                    for branch in range(self.count):
                        self.emit(stream, dict(type='message', id=f'abandoned{branch}', parentId='r0',
                                              message=dict(role='assistant', content='excluded branch')))
                self.emit(stream, self.message(index))
                if self.shape == 'settings' and index == self.count // 2:
                    self.emit(stream, self.settings_row(index + 1))
            if self.shape == 'branches' and self.provider == 'claude':
                for branch in range(self.count):
                    self.emit(stream, dict(type='attachment', uuid=f'context{branch}', parentUuid='r0',
                                          attachment=dict(type='queued_command')))
            if self.shape == 'revisions':
                self.revision = self.count // 2
                self.emit(stream, self.message(self.revision, self.count + 1))
            if self.shape == 'undo':
                self.emit(stream, dict(type='context.undo', count=self.count // 2))
        return self

    def generate_lineage(self):
        # Thirty-two physical files exceed both the former eight-parent limit
        # and a small cache. Every canonical message has one mathematical ID
        # and body regardless of its physical source or header ordinal.
        depth = 32
        if self.count < depth:
            raise ValueError('lineage fixture requires at least 32 messages')
        base = None
        ordinal = 0
        for part in range(depth):
            identity = f'00000000-0000-0000-0000-{depth-part:012d}'
            target = self.path.parent / f'rollout-{identity}.jsonl'
            payload = dict(id=identity, history_mode='paginated')
            if base is not None:
                payload['history_base'] = base
            placement = self.settings_placement
            with target.open('wb') as stream:
                self.emit(stream, dict(ordinal=ordinal, type='session_meta', payload=payload))
                if part and placement == 'child': self.emit(stream, self.settings_row(ordinal, identity))
                ordinal += 1
                indices = list(range(self.count * part // depth, self.count * (part + 1) // depth))
                for position, index in enumerate(indices):
                    row = self.message(index, ordinal)
                    row['payload']['thread_id'] = identity
                    self.emit(stream, row)
                    if placement == 'middle' and position == len(indices) // 2: self.emit(stream, self.settings_row(ordinal, identity))
                    ordinal += 1
                # 'last': the repeat is the final row inside the fork prefix.
                if placement == 'last' and part < depth - 1: self.emit(stream, self.settings_row(ordinal - 1, identity))
            end = target.stat().st_size
            # 'after': the repeat is the first parent row past the child's cutoff
            # (control: excluded by the cutoff, never parsed).
            if placement == 'after' and part < depth - 1:
                with target.open('ab') as stream: self.emit(stream, self.settings_row(ordinal - 1, identity))
            base = dict(thread_id=identity, end_ordinal_exclusive=ordinal, end_byte_offset=end)
        return self

    def expected_text(self, position):
        offset = int(self.provider in {'pi', 'kimi'})
        index = position - offset
        if not 0 <= index < self.selected_messages: return None
        if self.skipped and index >= self.skipped[0]: index += self.skipped[1] - self.skipped[0]
        # A same-turn revision keeps the revised item's canonical position.
        if self.revised_into is not None and index == self.revised_into: return self.text(self.rewritten)
        return self.text(index)

    def rewrite_and_append(self, index=5):
        if self.shape != 'linear' or self.provider not in {'claude', 'codex'}:
            raise ValueError('rewrite fixture requires linear Claude/Codex')
        # Equal-width interior mutation, followed by growth on the same inode.
        # Do not touch the header or final boundary witness.
        before = self.text(index).encode()
        with self.path.open('r+b') as stream:
            for _ in range(index + int(self.provider == 'codex')):
                stream.readline()
            start = stream.tell(); line = stream.readline()
            if before not in line:
                raise AssertionError('rewrite target missing')
            self.rewritten = index
            changed = line.replace(before, self.text(index).encode(), 1)
            if self.provider == 'claude':
                # Change cached graph membership, not only lazily read prose.
                changed = changed.replace(f'"parentUuid":"r{index-1}"'.encode(), b'"parentUuid":"r0"')
                self.skipped = (1, index)
            else:
                # Same-width identity edit turns the item into a same-turn
                # revision of its predecessor: cached dedup metadata must be
                # rebuilt, not only lazily read prose. Item ownership
                # (thread_id) is not a Codex selection rule.
                changed = changed.replace(f'"id":"r{index}"'.encode(), f'"id":"r{index-1}"'.encode(), 1)
                self.skipped = (index, index + 1)
                self.revised_into = index - 1
            if len(changed) != len(line):
                raise AssertionError('rewrite changed physical offsets')
            stream.seek(start); stream.write(changed)
            stream.seek(0, os.SEEK_END); self.emit(stream, self.message(self.count))
        self.count += 1


class WindowClient:
    """One owned helper and at most four retained protocol pages.

    RSS is the helper's high water from page.end plus sampled helper RSS. No
    provider child is launched (PATH is empty). This is not a kernel memory cap.
    """
    def __init__(self, binary, history, timeout=60, rss_limit=256 * 1024 * 1024):
        self.binary, self.history = Path(binary).resolve(), history
        self.timeout, self.rss_limit = timeout, rss_limit
        self.process = self.stream = self.watcher = None
        self.stop = threading.Event()
        self.failure = None
        self.sampled_peak = self.host_peak = self.bytes_read = self.wire_bytes = 0
        self.number = self.version = 0
        self.pages = deque(maxlen=4)
        self.head = self.thread = None
        self.page_count = 0
        self.first_page_bytes = self.warm_page_bytes_max = self.older_page_count = self.rss_samples = 0
        self.older_ms_total = self.older_ms_max = 0.0

    def __enter__(self):
        root = self.history.root
        environment = dict(os.environ, CODEX_HOME=str(root / 'codex'), CLAUDE_CONFIG_DIR=str(root / 'claude'),
                           PI_CODING_AGENT_DIR=str(root / 'pi'), KIMI_CODE_HOME=str(root / 'kimi'),
                           XDG_DATA_HOME=str(root / 'xdg'), PATH=str(root / 'empty-bin'))
        (root / 'empty-bin').mkdir(exist_ok=True)
        runtime = self.runtime = root / 'runtime'
        self.started = time.monotonic()
        self.deadline = self.started + self.timeout
        self.process = subprocess.Popen([str(self.binary), 'serve', '--runtime', str(runtime),
            '--idle-ms', '30000', '--lease-ms', '30000'], env=environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.watcher = threading.Thread(target=self.watch, daemon=True); self.watcher.start()
        try:
            self.stream = socket.socket(socket.AF_UNIX)
            while True:
                self.check()
                try:
                    self.stream.connect(str(runtime / 'client.sock')); break
                except (FileNotFoundError, ConnectionRefusedError):
                    self.stop.wait(.005)
            self.one(dict(kind='hello', v=3), 'hello')
            self.thread = self.one(dict(kind='resolve', provider=self.history.provider,
                                        transcriptRef=str(self.history.path)), 'resolved')['thread']
            return self
        except BaseException:
            self.__exit__(None, None, None); raise

    def __exit__(self, *_):
        self.stop.set()
        if self.stream: self.stream.close()
        if self.process:
            if self.process.poll() is None: self.process.terminate()
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait(timeout=3)
        if self.watcher: self.watcher.join(timeout=3)

    def watch(self):
        while not self.stop.wait(.05):
            if time.monotonic() >= self.deadline:
                self.failure = 'caseDeadline'; self.process.kill(); return
            try:
                sample = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(self.process.pid)],
                                        capture_output=True, timeout=2, text=True)
                if sample.returncode == 0 and sample.stdout.strip():
                    self.rss_samples += 1
                    self.sampled_peak = max(self.sampled_peak, int(sample.stdout.strip()) * 1024)
                    if self.sampled_peak > self.rss_limit:
                        self.failure = 'helperMemoryGuard'; self.process.kill(); return
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.failure = 'rssSamplerFailed'; self.process.kill(); return

    def check(self):
        if self.failure: raise RuntimeError(self.failure)
        if time.monotonic() >= self.deadline: raise TimeoutError('caseDeadline')
        if self.process.poll() is not None: raise RuntimeError(f'helperExited:{self.process.returncode}')

    def send(self, fields):
        self.check(); self.number += 1
        fields = dict(fields, id=f'synthetic-{self.number}')
        payload = json.dumps(fields, separators=(',', ':')).encode()
        self.stream.settimeout(max(.001, self.deadline - time.monotonic()))
        self.stream.sendall(struct.pack('!I', len(payload)) + payload)
        return fields['id']

    def receive(self, identifier):
        def exact(length):
            data = bytearray()
            while len(data) < length:
                self.check()
                if not select.select([self.stream], [], [], min(.1, max(0, self.deadline - time.monotonic())))[0]: continue
                chunk = self.stream.recv(length - len(data))
                if not chunk: self.check(); raise EOFError('helperEOF')
                data.extend(chunk)
            return data
        size, = struct.unpack('!I', exact(4))
        if not 0 < size <= 65536: raise AssertionError('frame limit')
        self.wire_bytes += size + 4
        value = json.loads(exact(size))
        if value.get('id') != identifier: raise AssertionError('response identity')
        if value.get('kind') == 'error': raise RuntimeError(value.get('code', 'unknownNativeError'))
        return value

    def one(self, fields, kind):
        value = self.receive(self.send(fields))
        if value['kind'] != kind: raise AssertionError(f'expected {kind}, got {value["kind"]}')
        return value

    def page(self, operation='bootstrap'):
        fields = dict(kind='window.read', thread=self.thread, operation=operation, windowVersion=self.version)
        if operation != 'bootstrap':
            descriptor = self.pages[0] if operation == 'before' else self.pages[-1]
            fields['cursor'] = descriptor[operation]
        started = time.monotonic(); identifier = self.send(fields)
        page_wire_start = self.wire_bytes
        begin = self.receive(identifier)
        if begin['kind'] != 'page.begin': raise AssertionError('page begin')
        records = []
        while True:
            value = self.receive(identifier)
            if value['kind'] == 'page.end': break
            if value['kind'] != 'page.record' or len(records) >= 100: raise AssertionError('record limit')
            records.append(value)
        elapsed = (time.monotonic() - started) * 1000
        if self.wire_bytes - page_wire_start > 262144 or value['records'] != len(records):
            raise AssertionError('page envelope')
        if not records: raise AssertionError('unexpected empty page')
        positions = [row['order'] for row in records]
        if positions != list(range(positions[0], positions[0] + len(records))):
            raise AssertionError('non-contiguous canonical order')
        for row in records:
            if row['recordID'] != f'{begin["sourceIdentity"]}:{row["order"]}':
                raise AssertionError('unstable canonical record ID')
            texts = [block['text'] for block in row['record'].get('blocks', []) if block.get('type') == 'text']
            expected = self.history.expected_text(row['order'])
            if texts != ([] if expected is None else [expected]):
                raise AssertionError(f'canonical body mismatch at order {row["order"]}')
        descriptor = value['window']
        low, high = positions[0], positions[-1] + 1
        if operation == 'bootstrap' and high != self.history.selected_records: raise AssertionError('latest page incomplete')
        if operation == 'before' and high != self.pages[0]['low']: raise AssertionError('older page gap/duplicate')
        if operation == 'after' and low != self.pages[-1]['high']: raise AssertionError('newer page gap/duplicate')
        if descriptor['hasOlder'] != (low > 0) or descriptor['hasNewer'] != (high < self.history.selected_records):
            raise AssertionError('history boundary flags')
        descriptor = dict(descriptor, low=low, high=high)
        if operation == 'bootstrap': self.pages.clear(); self.head = descriptor['segmentID']
        if operation == 'before': self.pages.appendleft(descriptor)
        else: self.pages.append(descriptor)
        self.version = descriptor['version']
        self.one(dict(kind='window.ack', thread=self.thread, transaction=identifier, windowVersion=self.version,
                      viewport=[page['segmentID'] for page in self.pages], head=self.head), 'window.acked')
        self.bytes_read += value['bytesRead']
        if self.page_count == 0: self.first_page_bytes = value['bytesRead']
        else: self.warm_page_bytes_max = max(self.warm_page_bytes_max, value['bytesRead'])
        self.host_peak = max(self.host_peak, value['hostPeakRSSBytes'])
        if self.host_peak > self.rss_limit: raise AssertionError('helperPeakMemoryGuard')
        self.page_count += 1
        if operation == 'before':
            self.older_page_count += 1
            self.older_ms_total += elapsed; self.older_ms_max = max(self.older_ms_max, elapsed)
        return elapsed

    def reconnect(self, interrupt=False):
        if interrupt:
            # Disconnect with a real admitted/queued request, without waiting
            # for its reply or ACK. The new connection must own fresh cursors.
            self.send(dict(kind='window.read', thread=self.thread, operation='bootstrap', windowVersion=self.version))
        self.stream.close()
        self.stream = socket.socket(socket.AF_UNIX)
        self.stream.connect(str(self.runtime / 'client.sock'))
        self.one(dict(kind='hello', v=3), 'hello')
        self.thread = self.one(dict(kind='resolve', provider=self.history.provider,
                                    transcriptRef=str(self.history.path)), 'resolved')['thread']
        self.version = 0; self.pages.clear(); self.head = None

    def exercise(self, traverse=False, rewrite=False, reconnect=False, interrupt=False):
        first_ms = self.page()
        first_ready_ms = (time.monotonic() - self.started) * 1000
        for _ in range(2):
            if self.pages[0]['hasOlder']: self.page('before')
        initial_pages = self.page_count
        initial_ready_ms = (time.monotonic() - self.started) * 1000
        if reconnect or interrupt:
            self.reconnect(interrupt)
            self.page('bootstrap')
        if rewrite:
            self.history.rewrite_and_append()
            self.page('bootstrap')
            traverse = True
        if traverse:
            while self.pages[0]['hasOlder']: self.page('before')
            while self.pages[-1]['hasNewer']: self.page('after')
        self.check()
        return dict(first_page_ms=round(first_ms, 3), launch_to_first_page_ms=round(first_ready_ms, 3),
                    launch_to_initial_pages_ms=round(initial_ready_ms, 3), initial_pages=initial_pages,
                    pages=self.page_count, traversed_both_directions=traverse, interior_rewrite_plus_append=rewrite,
                    reconnected=reconnect or interrupt, disconnected_in_flight=interrupt,
                    older_page_ms_total=round(self.older_ms_total, 3), older_page_ms_max=round(self.older_ms_max, 3),
                    older_pages=self.older_page_count,
                    bytes_read=self.bytes_read, wire_bytes=self.wire_bytes, host_peak_rss_bytes=self.host_peak,
                    first_page_bytes_read=self.first_page_bytes, later_page_bytes_read_max=self.warm_page_bytes_max,
                    read_amplification=round(self.bytes_read / self.history.source_bytes, 3),
                    sampled_helper_peak_rss_bytes=self.sampled_peak, rss_samples=self.rss_samples,
                    retained_pages=len(self.pages))
