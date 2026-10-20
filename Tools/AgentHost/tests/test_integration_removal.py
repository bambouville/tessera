#!/usr/bin/env python3
"""Host-free removal regressions against the shared embedded program."""
import base64,json,os,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
source=(ROOT/'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentIntegrationRemoval.swift').read_text()
PROGRAM=source.split('static let removalProgram = #"""\n',1)[1].split('\n"""#',1)[0]
RC='[ -r "$HOME/.config/tessera/agent-lifecycle.sh" ] && . "$HOME/.config/tessera/agent-lifecycle.sh" # TESSERA-AGENT-LIFECYCLE'
PROGRAM=PROGRAM.replace('__RC_MARKERS__',base64.b64encode(json.dumps([RC]).encode()).decode())
class RemovalTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='tessera-removal-');self.home=Path(self.temp.name)
        self.env=dict(os.environ,HOME=str(self.home))
        for key in ['CODEX_HOME','CLAUDE_CONFIG_DIR','KIMI_CODE_HOME','ZDOTDIR']: self.env.pop(key,None)
        self.support=self.home/'.config/tessera';self.support.mkdir(parents=True,mode=0o700)
        (self.support/'agent-lifecycle-hook.sh').write_text('synthetic helper')
        (self.support/'user-note').write_text('retain')
        (self.home/'.bashrc').write_text('export USER_SETTING=yes\n'+RC+'\n')
        (self.home/'.claude').mkdir()
        self.settings=self.home/'.claude/settings.json'
        self.owned={'type':'command','command':'"$HOME/.config/tessera/agent-lifecycle-hook.sh" claude Stop idle turn-stopped'}
        self.native={'type':'command','command':'"$HOME/.config/tessera/tessera-agent-host" hook --runtime-base "$HOME/.config/tessera/agent-host"'}
        self.user={'type':'command','command':'echo user-hook'}
        self.settings.write_text(json.dumps({'preferences':{'keep':True},'hooks':{'Stop':[{'hooks':[self.owned,self.native,self.user]}]}}))
    def tearDown(self): self.temp.cleanup()
    def run_remove(self): return subprocess.run(['python3','-c',PROGRAM],env=self.env,capture_output=True,timeout=5)
    def test_preserves_user_hooks_and_is_repeatable(self):
        for _ in range(2): self.assertEqual(self.run_remove().returncode,0)
        config=json.loads(self.settings.read_text())
        self.assertEqual(config['hooks']['Stop'][0]['hooks'],[self.user])
        self.assertTrue(config['preferences']['keep'])
        self.assertEqual((self.home/'.bashrc').read_text(),'export USER_SETTING=yes\n')
        self.assertFalse((self.support/'agent-lifecycle-hook.sh').exists())
        self.assertEqual((self.support/'user-note').read_text(),'retain')
    def test_invalid_config_prevents_all_changes(self):
        before=(self.home/'.bashrc').read_bytes();self.settings.write_text('{invalid')
        self.assertNotEqual(self.run_remove().returncode,0)
        self.assertEqual((self.home/'.bashrc').read_bytes(),before)
        self.assertTrue((self.support/'agent-lifecycle-hook.sh').exists())
    def test_symlink_config_retains_symlink(self):
        target=self.home/'dotfiles.json';self.settings.rename(target);self.settings.symlink_to(target)
        self.assertEqual(self.run_remove().returncode,0)
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(json.loads(target.read_text())['hooks']['Stop'][0]['hooks'],[self.user])
    def test_incomplete_kimi_section_fails_without_removing_hooks(self):
        kimi=self.home/'.kimi-code';kimi.mkdir();(kimi/'config.toml').write_text('# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN\n')
        self.assertNotEqual(self.run_remove().returncode,0)
        self.assertTrue((self.support/'agent-lifecycle-hook.sh').exists())
    def test_custom_directories_and_kimi_section(self):
        custom=self.home/'custom';custom.mkdir();self.settings.rename(custom/'settings.json')
        self.env['CLAUDE_CONFIG_DIR']=str(custom);self.env['KIMI_CODE_HOME']=str(custom)
        (custom/'config.toml').write_text('model="keep"\n# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN\n[[hooks]]\nevent="Stop"\n# TESSERA-AGENT-CENTER-KIMI-HOOKS-END\n')
        self.assertEqual(self.run_remove().returncode,0)
        self.assertEqual((custom/'config.toml').read_text(),'model="keep"\n')
if __name__=='__main__': unittest.main()
