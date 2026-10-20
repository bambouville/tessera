"""Compile an owned native launcher for a synthetic Python provider fixture.

Production automatic discovery deliberately rejects PATH scripts. The launcher
pins both its interpreter and fixture by absolute path without a second lookup.
"""
import json
import subprocess
import sys


def native_mock(executable):
    # The integration account may use umask 002; trust-boundary fixtures must
    # not accidentally create a group-writable executable directory.
    executable.parent.chmod(0o700)
    script = executable.with_suffix('.py')
    executable.rename(script)
    source = executable.with_suffix('.c')
    source.write_text('#include <unistd.h>\nint main(int argc,char**argv){char*args[32]={' +
        json.dumps(sys.executable) + ',' + json.dumps(str(script)) +
        '};for(int i=1;i<argc&&i<30;i++)args[i+1]=argv[i];execv(args[0],args);return 127;}')
    subprocess.run(['cc', str(source), '-o', str(executable)], check=True, capture_output=True)
    executable.chmod(0o700)
