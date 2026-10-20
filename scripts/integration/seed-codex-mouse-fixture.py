#!/usr/bin/env python3
"""Seed a synthetic Codex conversation without credentials or provider calls."""
import datetime, json, pathlib, sys, uuid
root = pathlib.Path(sys.argv[1])
home = root / 'home'
workspace = root / 'workspace'
workspace.mkdir(parents=True, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
sessions = home / 'sessions' / now.strftime('%Y/%m/%d')
sessions.mkdir(parents=True, exist_ok=True)
thread = str(uuid.uuid4())
timestamp = now.isoformat().replace('+00:00', 'Z')
(home / 'config.toml').write_text('''model = "offline-fixture"
model_provider = "offline"
check_for_update_on_startup = false
approval_policy = "never"
[tui]
alternate_screen = "always"
[model_providers.offline]
name = "Offline test fixture"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
requires_openai_auth = false
[projects."''' + str(workspace) + '''"]
trust_level = "trusted"
''')
answer = '\n'.join(f'ROW_{i:05d} | offline Codex scroll fixture' for i in range(1, 301))
records = [
 ('session_meta', dict(id=thread, session_id=thread, timestamp=timestamp, cwd=str(workspace), originator='codex_cli_rs', cli_version='0.160.0', source='cli', model_provider='offline', history_mode='legacy')),
 ('response_item', dict(type='message', role='user', content=[dict(type='input_text', text='Show the numbered offline fixture transcript.')])),
 ('event_msg', dict(type='user_message', message='Show the numbered offline fixture transcript.', images=[], local_images=[])),
 ('response_item', dict(type='message', role='assistant', content=[dict(type='output_text', text=answer)], phase='final_answer')),
 ('event_msg', dict(type='agent_message', message=answer, phase='final_answer')),
 ('event_msg', dict(type='task_complete', turn_id=str(uuid.uuid4()), last_agent_message=answer)),
]
(sessions / f'rollout-{now.strftime("%Y-%m-%dT%H-%M-%S")}-{thread}.jsonl').write_text(''.join(json.dumps(dict(timestamp=timestamp,type=kind,payload=payload))+'\n' for kind,payload in records))
(root / 'thread-id').write_text(thread)
launcher = root / 'run.py'
launcher.write_text('import os,pathlib\nr=pathlib.Path(__file__).parent\nos.chdir(r/"workspace")\ne=dict(os.environ, CODEX_HOME=str(r/"home"), CODEX_DISABLE_UPDATE_CHECK="1")\nos.execve(str(r/"codex-x86_64-unknown-linux-musl"), ["codex", "--no-daemon", "resume", (r/"thread-id").read_text()], e)\n')
print(thread)
