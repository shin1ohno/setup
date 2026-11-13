"""Lifecycle selectors fail closed against a fake Herdr process and ledger."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import tasks


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.owner = '/fixture/socket#w1:p1'
        self.record = dict(id='a'*16, owner=self.owner, state='reviewing',
                           envelope_receipt='receipt', history=[], attempts=[dict(
                               number=1, pane='w1:p2', terminal_id='term2', kind='codex',
                               agent='worker', route='herdr1', requested_model='model', observed_model='model',
                               effort='low', observed_effort='low')])
        self.panes = [dict(pane_id='w1:p1', terminal_id='term1', agent='claude', agent_status='working'),
                      dict(pane_id='w1:p2', terminal_id='term2', name='worker', agent='codex', agent_status='idle')]
        fake = self.root/'herdr'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root=Path(os.environ['FAKE_HERDR'])
a=sys.argv[3:]
with (root/'calls').open('a') as f: f.write(' '.join(a)+'\\n')
if a==['status','server']: print('socket: '+(root/'socket').read_text())
elif a==['workspace','list']: print(json.dumps({'result':{'workspaces':[{'workspace_id':'w1'}]}}))
elif a==['pane','list','--workspace','w1']: print(json.dumps({'result':{'panes':json.loads((root/'panes').read_text())}}))
elif a[:2]==['agent','get']: print(json.dumps({'result':{'agent':next(p for p in json.loads((root/'panes').read_text()) if p['pane_id']==a[2])}}))
else: sys.exit(17)
''')
        fake.chmod(0o700)
        self.env = patch.dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'],
                              FAKE_HERDR=str(self.root))
        self.env.start()
        self.addCleanup(self.env.stop)
        (self.root/'socket').write_text('/fixture/socket')

    def select(self, record=None, panes=None, others=()):
        for path in self.root.glob('*/task.json'): path.unlink()
        for t in [record or self.record, *others]: tasks.save_task(self.root, t)
        (self.root/'panes').write_text(json.dumps(self.panes if panes is None else panes))
        args=tasks.parser().parse_args(['closable','--owner',self.owner,'--herdr-session','fixture'])
        result=tasks.run(args,self.root)
        self.assertTrue(result['read_only'])
        self.assertNotIn('close', (self.root/'calls').read_text())
        return result['candidates']

    def test_positive_and_each_gate_mutation(self):
        self.assertEqual(len(self.select()),1)  # Positive control for every negative.
        for field, value in [('state','running'),('state','starting'),('state','retry'),
                             ('owner','/fixture/socket#'),
                             ('owner','/other/socket#w1:p1'),('envelope_receipt',None)]:
            with self.subTest(field=field,value=value):
                r=copy.deepcopy(self.record); r[field]=value
                self.assertEqual(self.select(r),[])
        for field,value in [('terminal_id',None),('terminal_id','replaced'),('kind','claude'),('agent','replacement'),
                            ('route','hc'),('observed_model','wrong'),('observed_effort','high')]:
            with self.subTest(field=field,value=value):
                r=copy.deepcopy(self.record); r['attempts'][0][field]=value
                self.assertEqual(self.select(r),[])
        for value in ['working','blocked','unknown',None]:
            p=copy.deepcopy(self.panes); p[1]['agent_status']=value
            self.assertEqual(self.select(panes=p),[])
        self.assertEqual(self.select(panes=self.panes[:1]),[])
        r=copy.deepcopy(self.record); r['attempts'][0]['pane']='w1:p1'
        self.assertEqual(self.select(r),[])
        r=copy.deepcopy(self.record); r['attempts'].append(copy.deepcopy(r['attempts'][0]))
        self.assertEqual(self.select(r),[])

    def test_orphan_is_absent_owner_not_idle_owner(self):
        r=copy.deepcopy(self.record); r['owner']='/fixture/socket#w9:p1'
        self.assertEqual(self.select(r)[0]['reason'],'orphan')
        p=self.panes+[dict(pane_id='w9:p1',agent_status='idle')]
        self.assertEqual(self.select(r,p),[])
        r['state']='running'
        self.assertEqual(self.select(r),[])

    def test_helpers_legacy_and_unrecorded(self):
        r=copy.deepcopy(self.record)
        r['attempts'][0].pop('route')
        r['attempts'][0]['helpers']=[dict(pane='w1:p3',terminal_id='term3',kind='claude',agent='helper')]
        p=self.panes+[dict(pane_id='w1:p3',terminal_id='term3',name='helper',agent='claude',agent_status='done'),
                      dict(pane_id='w1:p4',terminal_id='term4',agent='claude',agent_status='idle')]
        self.assertEqual({c['pane'] for c in self.select(r,p)}, {'w1:p2','w1:p3'})
        other=copy.deepcopy(r); other['id']='b'*16; other['owner']='/fixture/socket#w8:p1'
        self.assertEqual(self.select(r,p,others=[other]),[])

    def test_inventory_failure_and_wrong_socket_fail_closed(self):
        self.select()
        (self.root/'socket').write_text('/different/socket')
        with self.assertRaises(ValueError): self.select()
        (self.root/'socket').write_text('/fixture/socket')
        with self.assertRaises(ValueError): self.select(panes=self.panes[1:])

    def test_resume_snapshot_new_pane_and_identity_guards(self):
        def run(*args): return tasks.run(tasks.parser().parse_args(args), self.root)
        t=run('new','--owner',self.owner,'--cwd',str(self.root),'--topic','resume',
              '--scope','test','--acceptance','works')['task']['id']
        plan=self.root/'plan.json'
        original=dict(route='herdr1',harness='codex',launch_ready=True,
                      argv=['codex','--no-daemon','-m','model'],env_set={'CODEX_HOME':'/home/profile'},
                      env_unset=['CODEX_API_KEY'])
        plan.write_text(json.dumps(original))
        common=['--owner',self.owner,'--kind','codex','--model','model','--effort','low',
                '--profile','dev','--route','herdr1','--reason','test']
        run('attempt',t,*common,'--plan',str(plan),'--launch-options','["-a", "never"]')
        record=tasks.read_task(self.root,t)
        record['state']='retry'
        record['attempts'][0].update(observed_session='11111111-1111-1111-1111-111111111111',
                                     observed_model='model',observed_effort='low',
                                     launch_prompt='original',pane='w1:p2')
        tasks.save_task(self.root,record)
        for flag,value in [('--kind','claude'),('--model','different'),('--effort','high'),
                           ('--profile','common'),('--route','hc')]:
            changed=list(common); changed[changed.index(flag)+1]=value
            with self.assertRaises(ValueError): run('attempt',t,*changed,'--reuse-agent')
        plan.write_text('{}')  # Resume must not read the mutable plan file.
        resumed=run('attempt',t,*common,'--reuse-agent')['attempt']
        self.assertEqual(resumed['launch_plan'],original)
        run('bind',t,'--owner',self.owner,'--pane','w1:p3','--terminal-id','term3')
        launch=run('launch-command',t,'--owner',self.owner,'--prompt','recall context')
        self.assertEqual(launch['argv'][1:3],['resume',resumed['resume_session']])
        self.assertEqual(launch['argv'][-3:],['recall context','-a','never'])
        self.assertEqual(launch['env_set'],original['env_set'])
        # Same session, but only this attempt's turns are model evidence.
        def log(session, at='2100-01-01T00:00:00Z'):
            p=self.root/('rollout-test-'+session+'.jsonl')
            rows=[dict(type='session_meta',payload=dict(id=session,cwd=str(self.root))),
                  dict(type='event_msg',payload=dict(type='item_completed',item=dict(
                      type='UserMessage',content=[dict(type='text',text='original')]))),
                  dict(type='turn_context',timestamp=at,payload=dict(model='model',effort='low'))]
            p.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
            return str(p)
        run('observe',t,'--owner',self.owner,'--transcript',log(resumed['resume_session']),
            '--launch-prompt','original')
        with self.assertRaisesRegex(ValueError,'session identity'):
            run('observe',t,'--owner',self.owner,
                '--transcript',log('22222222-2222-2222-2222-222222222222'),
                '--launch-prompt','original')
        with self.assertRaises(ValueError):
            run('observe',t,'--owner',self.owner,
                '--transcript',log(resumed['resume_session'],'2000-01-01T00:00:00Z'),
                '--launch-prompt','original')
        with self.assertRaises(ValueError):
            run('bind',t,'--owner',self.owner,'--pane','w1:p4')
        run('helper',t,'--owner',self.owner,'--pane','w1:p5','--terminal-id','term5',
            '--kind','codex','--agent-name','helper')
        run('helper',t,'--owner',self.owner,'--pane','w1:p6','--terminal-id','term6',
            '--kind','shell')
        self.assertEqual(len(tasks.read_task(self.root,t)['attempts'][-1]['helpers']),2)
        with self.assertRaises(ValueError):
            run('helper',t,'--owner',self.owner,'--pane','w1:p5','--terminal-id','term5',
                '--kind','codex','--agent-name','helper')

if __name__ == '__main__': unittest.main()
