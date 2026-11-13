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
elif a[:2]==['agent','get']: print(json.dumps({'result':{'agent':next(p for p in json.loads((root/('agents' if (root/'agents').exists() else 'panes')).read_text()) if p['pane_id']==a[2])}}))
elif a[:2]==['pane','split']: print(json.dumps({'result':{'pane':{'pane_id':'w1:p5','terminal_id':'term5'}}}))
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
        for field,value in [('terminal_id','replaced'),('kind','claude'),('agent','replacement'),
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
        r['attempts'][0]['helpers']=[dict(pane='w1:p3',terminal_id='term3',kind='claude',agent='helper',creation_receipt={'result':{'pane':{'pane_id':'w1:p3','terminal_id':'term3'}}})]
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
        t=run('new','--linear-waiver','Owner fixture waiver','--owner',self.owner,'--cwd',str(self.root),'--topic','resume',
              '--scope','test','--acceptance','works')['task']['id']
        plan=self.root/'plan.json'
        original=dict(route='herdr1',harness='codex',profile='dev',launch_ready=True,
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
        # Older records may predate the profile field; do not break their reuse.
        legacy=tasks.read_task(self.root,t)
        legacy['attempts'][0].pop('profile')
        tasks.save_task(self.root,legacy)
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
        # An arbitrary existing pane cannot be registered as a trusted helper.
        with self.assertRaisesRegex(ValueError,'creation receipt'):
            run('helper',t,'--owner',self.owner,'--pane','w1:p5','--terminal-id','term5',
                '--kind','codex','--agent-name','helper')
        current=tasks.read_task(self.root,t); current['state']='running'
        tasks.save_task(self.root,current)
        run('helper-open',t,'--owner',self.owner,'--herdr-session','fixture')
        run('helper',t,'--owner',self.owner,'--pane','w1:p5','--terminal-id','term5',
            '--kind','codex','--agent-name','helper')
        self.assertEqual(len(tasks.read_task(self.root,t)['attempts'][-1]['helpers']),1)

    def test_adoption_is_read_only_until_explicit_flag(self):
        r=copy.deepcopy(self.record); r['attempts'][0].pop('terminal_id')
        selected=self.select(r)
        self.assertEqual(selected[0]['terminal_id'],'term2')
        self.assertTrue(selected[0]['adoption'])
        self.assertNotIn('terminal_id',tasks.read_task(self.root,r['id'])['attempts'][0])
        args=tasks.parser().parse_args(['closable','--owner',self.owner,
                                     '--herdr-session','fixture','--adopt'])
        self.assertFalse(tasks.run(args,self.root)['read_only'])
        adopted=tasks.read_task(self.root,r['id'])
        self.assertEqual(adopted['attempts'][0]['terminal_id'],'term2')
        self.assertEqual(adopted['history'][-1]['adoption']['agent'],'worker')
        for field,value in [('name','other'),('agent','claude'),('agent',None),('agent_status','working')]:
            p=copy.deepcopy(self.panes);p[1][field]=value
            self.assertEqual(self.select(r,p),[])
        r['owner']='/fixture/socket#w9:p1'
        self.assertEqual(self.select(r)[0]['reason'],'orphan')
        self.assertEqual(self.select(r,self.panes+[dict(pane_id='w9:p1')]),[])

    def test_missing_observation_and_supervision_pause(self):
        r=copy.deepcopy(self.record); a=r['attempts'][0]
        a['observed_model']=a['observed_effort']=None
        r['state']='cancelled'
        self.assertEqual(len(self.select(r)),1)
        r['state']='needs-user'; r.pop('envelope_receipt')
        a['native_session']='11111111-1111-1111-1111-111111111111'
        self.assertEqual(self.select(r),[])
        r['owner']='/fixture/socket#w9:p1'
        self.assertEqual(self.select(r),[])  # An orphan is not proof of completion.
        r['owner']=self.owner
        self.select(r)
        args=tasks.parser().parse_args(['settle',r['id'],'--owner',self.owner,
            '--note','No background jobs remain','--evidence','inspected worker completion'])
        tasks.run(args,self.root)
        r=tasks.read_task(self.root,r['id'])
        self.assertEqual(len(self.select(r)),1)
        p=copy.deepcopy(self.panes);p[1]['agent_status']='working'
        self.assertEqual(self.select(r,p),[])
        r['attempts'][0]['native_session']='invalid'
        self.assertEqual(self.select(r),[])

    def test_same_live_pane_reuse_chain_is_not_ambiguous(self):
        r=copy.deepcopy(self.record)
        second=copy.deepcopy(r['attempts'][0]); second.update(number=2,reuse=True)
        second.pop('terminal_id'); r['attempts'].append(second)
        self.assertEqual(self.select(r)[0]['attempt'],2)
        legacy=copy.deepcopy(r);legacy['attempts'][0].pop('route')
        legacy['attempts'][1]['route']='herdr'
        self.assertEqual(self.select(legacy)[0]['attempt'],2)
        for field,value in [('reuse',False),('kind','claude'),('agent','other'),
                            ('route','hc'),('terminal_id','different'),('number',1)]:
            bad=copy.deepcopy(r);bad['attempts'][1][field]=value
            self.assertEqual(self.select(bad),[])
        p=copy.deepcopy(self.panes);p[1]['terminal_id']='replacement'
        self.assertEqual(self.select(r,p),[])

    def test_each_independent_inventory_gate(self):
        self.assertEqual(len(self.select()),1)
        r=copy.deepcopy(self.record);r['owner']='/other/socket#w9:p1'
        self.assertEqual(self.select(r),[])  # M01: absent owner on ANOTHER socket.
        with self.assertRaisesRegex(ValueError,'ambiguous pane inventory'):
            self.select(panes=self.panes+[self.panes[1]])  # M08
        # M03: caller is not also a ledger controller.
        r=copy.deepcopy(self.record);r['owner']='/fixture/socket#w9:p1'
        r['attempts'][0].update(pane='w1:p1',terminal_id='term1')
        p=copy.deepcopy(self.panes);p[0].update(agent='codex',name='worker',agent_status='idle')
        self.assertEqual(self.select(r,p),[])
        # M02: protect a controller other than the caller, even if misbound.
        r['attempts'][0].update(pane='w8:p1',terminal_id='term8')
        p=self.panes+[dict(pane_id='w8:p1',terminal_id='term8',agent='codex',name='worker',agent_status='idle')]
        controller=dict(id='b'*16,owner='/fixture/socket#w8:p1',state='running',attempts=[],history=[])
        self.assertEqual(self.select(r,p,others=[controller]),[])
        # M16: agent get sees replacement or work AFTER the pane-list snapshot.
        for field,value in [('terminal_id','replaced'),('agent','claude'),('agent_status','working')]:
            agents=copy.deepcopy(self.panes);agents[1][field]=value
            (self.root/'agents').write_text(json.dumps(agents))
            self.assertEqual(self.select(),[])
        (self.root/'agents').unlink()
        # M15: do not use a later idle read to erase a working/changed pane snapshot.
        (self.root/'agents').write_text(json.dumps(self.panes))
        for field,value in [('terminal_id','replaced'),('agent','claude'),('agent_status','working')]:
            panes=copy.deepcopy(self.panes);panes[1][field]=value
            self.assertEqual(self.select(panes=panes),[])
        (self.root/'agents').unlink()

    def test_hc_path_resume_guards_and_unknown_profile(self):
        def run(*args): return tasks.run(tasks.parser().parse_args(args),self.root)
        t=run('new','--linear-waiver','Owner fixture waiver','--owner',self.owner,'--cwd',str(self.root),'--topic','fixture',
              '--scope','test','--acceptance','works')['task']['id']
        plan=self.root/'hc-plan.json'
        plan.write_text(json.dumps(dict(route='hc',harness='codex',profile='common',
            launch_ready=True,argv=['codex','--no-daemon'],env_set={},env_unset=[])))
        common=['--owner',self.owner,'--kind','codex','--model','model','--effort','low',
                '--profile','common','--route','hc','--reason','test']
        run('attempt',t,*common,'--plan',str(plan))
        original=tasks.read_task(self.root,t); original['state']='retry'
        a=original['attempts'][0]
        a.update(observed_session='11111111-1111-1111-1111-111111111111',
                 observed_model='model',observed_effort='low')
        tasks.save_task(self.root,original)
        with self.assertRaisesRegex(ValueError,'launch options'):
            run('attempt',t,*common,'--reuse-agent','--launch-options','["--other"]')
        # M12: a refused observation's session is not valid resume evidence.
        for field,value in [('observed_model',None),('observed_effort','high')]:
            bad=copy.deepcopy(original);bad['attempts'][0][field]=value
            tasks.save_task(self.root,bad)
            resumed=run('attempt',t,*common,'--reuse-agent')['attempt']
            self.assertIsNone(resumed['resume_session'])
        native=copy.deepcopy(original);native['state']='needs-user'
        native['attempts'][0].update(observed_model=None,observed_effort=None)
        tasks.save_task(self.root,native)
        with self.assertRaisesRegex(ValueError,'native session UUID'):
            run('settle',t,'--owner',self.owner,'--note','finished','--evidence','completion')
        session_id='33333333-3333-3333-3333-333333333333'
        run('settle',t,'--owner',self.owner,'--session-id',session_id,
            '--note','finished; no background work','--evidence','native session metadata')
        self.assertEqual(run('attempt',t,*common,'--reuse-agent')['attempt']['resume_session'],session_id)
        tasks.save_task(self.root,original)
        run('attempt',t,*common,'--reuse-agent')
        launch=run('launch-command',t,'--owner',self.owner,'--prompt','hello')
        self.assertEqual(launch['env_set']['PATH'],os.environ['PATH'])
        import shlex
        self.assertIn('PATH='+os.environ['PATH'],shlex.split(launch['command']))
        corrupt=tasks.read_task(self.root,t);corrupt['attempts'][-1]['resume_session']='not-a-uuid'
        tasks.save_task(self.root,corrupt)
        with self.assertRaisesRegex(ValueError,'UUID'):
            run('launch-command',t,'--owner',self.owner,'--prompt','hello')
        # D8: derive the old profile from the snapshot, or explicitly retain unknown.
        legacy=copy.deepcopy(original);legacy['attempts'][0].pop('profile')
        tasks.save_task(self.root,legacy)
        changed=list(common);changed[changed.index('--profile')+1]='dev'
        with self.assertRaisesRegex(ValueError,'profile'):
            run('attempt',t,*changed,'--reuse-agent')
        legacy['attempts'][0]['launch_plan'].pop('profile')
        tasks.save_task(self.root,legacy)
        self.assertIsNone(run('attempt',t,*changed,'--reuse-agent')['attempt']['profile'])

    def test_helper_cannot_claim_existing_pane_or_controller(self):
        r=copy.deepcopy(self.record);r['state']='running'
        r['attempts'][0]['helpers']=[dict(pane=p,terminal_id=t,kind='shell',
            creation_receipt={'result':{'pane':{'pane_id':p,'terminal_id':t}}})
            for p,t in [('w1:p1','term1'),('w1:p2','term2'),('w1:p5','term5')]]
        self.select(r)
        def register(pane,terminal,*extra):
            args=tasks.parser().parse_args(['helper',r['id'],'--owner',self.owner,
                '--pane',pane,'--terminal-id',terminal,'--kind','codex',*extra])
            return tasks.run(args,self.root)
        for pane,terminal in [('w1:p1','term1'),('w1:p2','term2')]:
            with self.assertRaisesRegex(ValueError,'controller or worker'):
                register(pane,terminal,'--agent-name','helper')
        with self.assertRaisesRegex(ValueError,'live agent name'):
            register('w1:p5','term5')
        with self.assertRaisesRegex(ValueError,'creation receipt'):
            register('w1:p6','term6','--agent-name','helper')
        with self.assertRaisesRegex(ValueError,'creation receipt'):
            register('w1:p5','changed','--agent-name','helper')
        # Unconfirmed legacy helper registrations never authorize destruction.
        r=copy.deepcopy(self.record)
        r['attempts'][0]['helpers']=[dict(pane='w1:p3',terminal_id='term3',kind='claude',agent='helper')]
        p=self.panes+[dict(pane_id='w1:p3',terminal_id='term3',name='helper',agent='claude',agent_status='idle')]
        self.assertEqual({c['pane'] for c in self.select(r,p)}, {'w1:p2'})

if __name__ == '__main__': unittest.main()
