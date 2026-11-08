"""Execute the documented remote blocks against local, isolated host-shaped fakes."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import unittest

DOC = Path(__file__).resolve().parents[1] / 'references' / 'dispatch.md'


class RemoteDispatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.local = self.root / 'local'
        self.local.mkdir()
        self.remote = self.root / 'cos-0123456789abcdef-1'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.calls.touch()
        self.blocks = dict(re.findall(r'```bash\n# remote-phase: (\w+)\n(.*?)```', DOC.read_text(), re.S))
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        CALLS=str(self.calls), FAIL_AT='', TASK_STATE='accepted',
                        COS_STATE_DIR=str(self.root / 'ledger'))
        self.ledger = self.root / 'ledger.py'
        self.ledger.write_text('''import os,sys,json
with open(os.environ['CALLS'],'a') as f: f.write('ledger '+ ' '.join(sys.argv[1:])+'\\n')
if os.environ.get('FAIL_AT') == 'bind' and sys.argv[1]=='bind': sys.exit(1)
print(json.dumps({'task':{'state':os.environ.get('TASK_STATE')},'check':{'id':'check-id'}}))
''')
        self.fake('herdr', '''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f:f.write('herdr '+' '.join(args)+'\\n')
cmd=' '.join(args[2:4])
if os.environ.get('FAIL_AT')==cmd:sys.exit(1)
if cmd=='workspace create': print(json.dumps({'result':{'root_pane':{'pane_id':'w1:p1'},'workspace':{'workspace_id':'w1'}}}))
elif cmd=='agent wait':sys.exit(1)
else:print('{}')
''')
        self.fake('ssh', '''#!/usr/bin/env python3
import os,subprocess,sys,time
cmd=sys.argv[-1]
with open(os.environ['CALLS'],'a') as f:f.write('ssh '+cmd+'\\n')
if os.environ.get('FAIL_AT')=='ssh':sys.exit(255)
if os.environ.get('FAIL_AT')=='hang':time.sleep(10)
sys.exit(subprocess.call(['/bin/bash','-c',cmd]))
''')
        self.fake('scp', '''#!/usr/bin/env python3
import os,shutil,sys
with open(os.environ['CALLS'],'a') as f:f.write('scp '+' '.join(sys.argv[1:])+'\\n')
if os.environ.get('FAIL_AT')=='scp':sys.exit(1)
paths=[p.split(':',1)[-1] for p in sys.argv[1:]]
try:shutil.copyfile(*paths)
except OSError:sys.exit(1)
''')
        self.vars = self.root / 'vars.sh'
        self.values = dict(ledger=str(self.ledger), owner='socket#controller', machine='mini-id',
                           host='fixture', task='0123456789abcdef', attempt='1', worker='canary',
                           local_dir=str(self.local), remote_dir=str(self.remote),
                           session_id='ff08475d-0627-4047-89fd-86a87f58e8dc')
        self.write_vars()
        (self.local / 'brief-1.md').write_text('fixture')

    def fake(self, name, content):
        p = self.bin / name
        p.write_text(content)
        p.chmod(0o755)

    def write_vars(self):
        self.vars.write_text(''.join('export '+k+'='+shlex.quote(v)+'\n' for k,v in self.values.items()))
        self.env['dispatch_vars'] = str(self.vars)

    def run_block(self, phase, ok=True, shorten=False):
        block = self.blocks[phase]
        if shorten:
            self.assertIn('timeout --kill-after=2s 15s ssh', block)
            block = block.replace('15s ssh', '0.2s ssh')
        result = subprocess.run(['bash', '-c', block], env=self.env, text=True,
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def workspace(self):
        self.run_block('directory')
        self.run_block('workspace')

    def test_every_mutating_block_is_fail_fast(self):
        self.assertEqual(len(self.blocks), 8)
        for block in self.blocks.values():
            self.assertTrue(block.startswith('set -euo pipefail\n'))

    def test_directory_exclusive_private_with_marker(self):
        self.run_block('directory')
        self.assertEqual(self.remote.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.remote / '.cos-owner').read_text(),
                         (self.local / 'remote-1.token').read_text())
        self.run_block('directory', ok=False)
        self.assertEqual(self.calls.read_text().count('mkdir -m 700'), 1)

    def test_existing_remote_directory_not_adopted(self):
        self.remote.mkdir()
        self.run_block('directory', ok=False)
        self.assertFalse((self.remote / '.cos-owner').exists())

    def test_scp_failure_stops_before_create(self):
        self.run_block('directory')
        self.env['FAIL_AT'] = 'scp'
        self.run_block('workspace', ok=False)
        self.assertNotIn('workspace create', self.calls.read_text())
        self.assertNotIn('ledger bind', self.calls.read_text())

    def test_create_failure_stops_before_bind_and_refuses_retry(self):
        self.run_block('directory')
        self.env['FAIL_AT'] = 'workspace create'
        self.run_block('workspace', ok=False)
        self.env['FAIL_AT'] = ''
        self.run_block('workspace', ok=False)
        self.assertEqual(self.calls.read_text().count('workspace create'), 1)
        self.assertNotIn('ledger bind', self.calls.read_text())

    def test_recorded_create_without_intent_refuses_any_side_effect(self):
        (self.local / 'create-1.json').write_text('{}')
        self.run_block('workspace', ok=False)
        self.assertEqual(self.calls.read_text(), '')

    def test_bind_failure_stops_before_input(self):
        self.run_block('directory')
        self.env['FAIL_AT'] = 'bind'
        self.run_block('workspace', ok=False)
        self.assertNotIn('pane run', self.calls.read_text())

    def test_successful_workspace_is_not_created_twice(self):
        self.workspace()
        self.run_block('workspace', ok=False)
        self.assertEqual(self.calls.read_text().count('workspace create'), 1)

    def test_separate_shell_missing_config_fails(self):
        self.env.pop('dispatch_vars')
        self.run_block('launch', ok=False)
        self.assertEqual(self.calls.read_text(), '')

    def test_cleanup_requires_acceptance_close_and_marker(self):
        self.workspace()
        self.env['TASK_STATE'] = 'reviewing'
        self.run_block('cleanup', ok=False)
        self.assertNotIn('workspace close', self.calls.read_text())
        self.env['TASK_STATE'] = 'accepted'
        self.env['FAIL_AT'] = 'workspace close'
        self.run_block('cleanup', ok=False)
        self.assertNotIn('rm -rf', self.calls.read_text())
        self.env['FAIL_AT'] = ''
        (self.remote / '.cos-owner').write_text('wrong token')
        self.run_block('cleanup', ok=False)
        self.assertTrue(self.remote.exists())
        (self.remote / '.cos-owner').write_text((self.local / 'remote-1.token').read_text())
        self.run_block('cleanup')
        self.assertFalse(self.remote.exists())

    def test_transfer_does_not_overwrite_landing_file(self):
        (self.local / 'report-1.txt').write_text('keep')
        self.run_block('receive', ok=False)
        self.assertEqual((self.local / 'report-1.txt').read_text(), 'keep')
        self.assertNotIn('scp', self.calls.read_text())

    def test_attempt_two_cannot_transfer_attempt_one_report(self):
        self.run_block('directory')
        (self.remote / 'report-1.txt').write_text('old')
        self.values['attempt'] = '2'
        self.write_vars()
        self.run_block('receive', ok=False)
        self.assertNotIn('ledger receive', self.calls.read_text())
        self.assertFalse((self.local / 'report-2.txt').exists())

    def test_remote_ssh_has_real_wall_clock_bound(self):
        self.env['FAIL_AT'] = 'hang'
        start = time.monotonic()
        result = self.run_block('wait', shorten=True)
        self.assertLess(time.monotonic()-start, 3)
        self.assertIn('reason=transport', result.stdout)

    def test_atomic_temp_is_not_an_envelope(self):
        self.run_block('directory')
        (self.remote / 'envelope-1.tmp').write_text('{partial')
        self.env['FAIL_AT'] = 'agent get'
        self.assertIn('reason=gone', self.run_block('wait').stdout)
        (self.remote / 'envelope-1.tmp').rename(self.remote / 'envelope-1.json')
        self.assertIn('reason=envelope', self.run_block('wait').stdout)


if __name__ == '__main__':
    unittest.main()
