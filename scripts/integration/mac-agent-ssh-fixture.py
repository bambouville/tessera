#!/usr/bin/env python3
"""Opt-in, run-owned loopback sshd; never edits the Mac's SSH configuration.

The user's explicit Mac-host authorization is required. Keys, authorized_keys,
host trust and sshd configuration are private fixture artifacts. The server
accepts only its generated key and binds only 127.0.0.1. It is not installed as
a daemon. This standalone smoke verifies the transport prerequisite only.
"""
import argparse
import getpass
import json
import os
from pathlib import Path
import socket
import shlex
import subprocess
import tempfile
import time
import importlib.util

_spec = importlib.util.spec_from_file_location('owned_process', Path(__file__).with_name('owned-process.py'))
_owned = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_owned)


class MacSSHFixture:
    def __init__(self, forced_command=None):
        # sshd StrictModes checks every ancestor of AuthorizedKeysFile. Keep
        # this under the user's owned worktree, not world-writable /private/tmp.
        # .build is gitignored; private keys are removed by close on all exits.
        parent = Path(__file__).resolve().parents[2] / '.build'
        parent.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='tessera-mac-agent-ssh-', dir=parent))
        self.process = None
        self.log = None
        # Never expose an unrestricted shell on the user's account. A caller
        # can supply one fixed, run-owned non-daemonizing protocol command;
        # SSH_ORIGINAL_COMMAND is deliberately ignored.
        self.forced_command = forced_command or ['/usr/bin/printf', 'TESSERA_OWNED_MAC_SSH_OK']

    def __enter__(self):
        os.chmod(self.root, 0o700)
        try:
            for name in ('host', 'client'):
                subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.root / name)], check=True)
            (self.root / 'authorized_keys').write_text((self.root / 'client.pub').read_text())
            (self.root / 'authorized_keys').chmod(0o600)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                self.port = reservation.getsockname()[1]
            config = '\n'.join([
                f'Port {self.port}', 'ListenAddress 127.0.0.1',
                f'HostKey {self.root}/host', f'PidFile {self.root}/sshd.pid',
                f'AuthorizedKeysFile {self.root}/authorized_keys', f'AllowUsers {getpass.getuser()}',
                'StrictModes yes', 'UsePAM no', 'PasswordAuthentication no',
                'KbdInteractiveAuthentication no', 'PubkeyAuthentication yes', 'PermitRootLogin no',
                'AllowTcpForwarding no', 'AllowAgentForwarding no', 'X11Forwarding no',
                'PermitTunnel no', 'PermitUserEnvironment no',
                'ForceCommand ' + shlex.join(self.forced_command),
                'Subsystem sftp internal-sftp', 'PrintMotd no', 'UseDNS no', 'LogLevel ERROR', ''])
            (self.root / 'sshd_config').write_text(config)
            self.log = (self.root / 'sshd.log').open('wb')
            self.process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(self.root / 'sshd_config')],
                stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)
            deadline = time.monotonic() + 5
            while True:
                if self.process.poll() is not None: raise RuntimeError('owned sshd exited; inspect private sshd.log')
                try:
                    with socket.create_connection(('127.0.0.1', self.port), timeout=.2): break
                except OSError:
                    if time.monotonic() > deadline: raise TimeoutError('owned sshd startup')
                    time.sleep(.05)
            (self.root / 'known_hosts').write_text(f'[127.0.0.1]:{self.port} ' + (self.root / 'host.pub').read_text())
            self.command = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={self.root}/known_hosts',
                '-i', str(self.root / 'client'), '-p', str(self.port), f'{getpass.getuser()}@127.0.0.1']
            return self
        except BaseException:
            self.close()
            raise

    def close(self):
        with _owned.cleanup_signals():
            self._close()

    def _close(self):
        errors = []
        try:
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=3)
        except Exception as error:
            errors.append(type(error).__name__)
        try:
            if self.log: self.log.close()
        except Exception as error:
            errors.append(type(error).__name__)
        # No other server trusts these keys. Remove private keys even on
        # failure; retain non-secret diagnostics and public trust provenance.
        for name in ('client', 'host'):
            try:
                (self.root / name).unlink(missing_ok=True)
            except OSError as error:
                errors.append(type(error).__name__)
        if errors:
            raise RuntimeError('owned SSH fixture cleanup failed: ' + ', '.join(errors))

    def __exit__(self, *_): self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if os.environ.get('TESSERA_RUN_MAC_AGENT_SSH') != '1': parser.error('explicit Mac-host test opt-in required')
    os.umask(0o077)
    fixture = MacSSHFixture()
    print(json.dumps({'private_artifacts': str(fixture.root)}), flush=True)
    with fixture:
        # The forced command must ignore even a conflicting client request.
        result = subprocess.run(fixture.command + ['printf UNEXPECTED_REMOTE_COMMAND'], capture_output=True, timeout=10)
        (fixture.root / 'ssh-client.log').write_bytes(result.stderr)
        passed = result.returncode == 0 and result.stdout == b'TESSERA_OWNED_MAC_SSH_OK'
        evidence = {'ssh_exit': result.returncode, 'authenticated_roundtrip': passed, 'loopback_only': True,
            'global_ssh_config_modified': False, 'global_authorized_keys_modified': False}
    evidence['owned_server_exited'] = fixture.process is not None and fixture.process.poll() is not None
    evidence['private_keys_removed'] = all(not (fixture.root / name).exists() for name in ('client', 'host'))
    (fixture.root / 'content-free-results.json').write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence))
    return 0 if passed and evidence['owned_server_exited'] and evidence['private_keys_removed'] else 1


if __name__ == '__main__':
    with _owned.termination_cleanup():
        raise SystemExit(main())
