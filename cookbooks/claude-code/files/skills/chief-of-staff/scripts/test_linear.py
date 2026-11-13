"""Offline controller records, migration compatibility and independent close gates."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import tasks


class LinearTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.root = self.directory / 'state'
        self.root.mkdir()
        self.owner = '/socket#controller'

    def run_cli(self, *args):
        with tasks.locked(self.root):
            return tasks.run(tasks.parser().parse_args(args), self.root)

    def new(self, *args):
        return self.run_cli('new', '--owner', self.owner, '--topic', 'test',
                            '--cwd', str(self.directory), '--scope', 'fake only',
                            '--acceptance', 'verified', '--contract', 'legacy', *args)['task']

    def tracked(self, child='SH1-2', parent='SH1-1'):
        return self.new('--linear-child', child, '--linear-parent', parent)

    def mutate(self, task, command, *args):
        return self.run_cli(command, task['id'], '--owner', task['owner'], *args)

    def state(self, task, state, parent=False):
        return self.mutate(task, 'linear-state', '--state', state, '--note', 'Observed in Linear',
                           *(['--parent'] if parent else []))

    def update(self, task, state):
        return self.mutate(task, 'update', '--state', state, '--note', 'review', '--evidence', 'proof')

    def review_ready(self, task):
        self.mutate(task, 'attempt', '--profile', 'dev', '--kind', 'codex', '--model', 'fixture',
                    '--reason', 'test')
        self.mutate(task, 'bind', '--pane', 'worker')
        self.update(task, 'reviewing')

    def test_new_gate(self):
        with self.assertRaisesRegex(ValueError, 'new requires Linear'):
            self.new()
        for args in [('--linear-child', 'SH1-2'), ('--linear-parent', 'SH1-1'),
                     ('--linear-child', 'SH1-2', '--linear-parent', 'SH1-1', '--linear-waiver', 'owner')]:
            with self.assertRaisesRegex(ValueError, 'new requires Linear'):
                self.new(*args)
        task = self.new('--linear-waiver', 'Owner explicitly declined tracking')
        self.assertEqual(task['history'][0]['linear_waiver'],
                         {'owner': self.owner, 'reason': 'Owner explicitly declined tracking'})
        self.assertEqual(self.tracked()['linear']['parent'], 'SH1-1')

    def test_accepted_gate(self):
        task = self.tracked()
        self.review_ready(task)
        for state in (None, 'Todo', 'In Review', 'Canceled'):
            if state:
                self.state(task, state)
            with self.assertRaisesRegex(ValueError, 'Linear Done must be recorded'):
                self.update(task, 'accepted')
        self.state(task, 'Done')
        self.assertEqual(self.update(task, 'accepted')['task']['state'], 'accepted')

    def test_cancelled_gate(self):
        task = self.tracked()
        for state in (None, 'Todo', 'In Progress', 'Done'):
            if state:
                self.state(task, state)
            with self.assertRaisesRegex(ValueError, 'Linear Canceled must be recorded'):
                self.update(task, 'cancelled')
        self.state(task, 'Canceled')
        self.assertEqual(self.update(task, 'cancelled')['task']['state'], 'cancelled')

    def test_attach_history_and_existing_gate(self):
        task = self.new('--linear-waiver', 'fixture')
        task = self.mutate(task, 'linear-attach', '--child', 'SH1-2', '--parent', 'SH1-1',
                           '--note', 'owner elected tracking')['task']
        for state in tasks.LINEAR_STATES:
            task = self.state(task, state)['task']
        self.assertEqual([r['state'] for r in task['linear']['history']], list(tasks.LINEAR_STATES))
        self.assertTrue(all(r['note'] and r['at'] and r['owner'] for r in task['linear']['history']))
        with self.assertRaisesRegex(ValueError, 'already attached'):
            self.mutate(task, 'linear-attach', '--child', 'SH1-3', '--parent', 'SH1-1', '--note', 'replace')
        with self.assertRaisesRegex(ValueError, 'already belongs'):
            self.tracked()
        with self.assertRaisesRegex(ValueError, 'verified controller owner'):
            self.run_cli('linear-state', task['id'], '--owner', 'other', '--state', 'Done', '--note', 'bad')
        self.state(task, 'Done')
        # Linear close alone cannot bypass the existing transition/evidence gates.
        with self.assertRaisesRegex(ValueError, 'invalid transition'):
            self.update(task, 'accepted')

    def test_old_record_unchanged(self):
        task = self.new('--linear-waiver', 'fixture')
        task['history'] = []  # Exact pre-change shape, no waiver or Linear fields.
        tasks.save_task(self.root, task)
        self.review_ready(task)
        self.assertEqual(self.update(task, 'accepted')['task']['state'], 'accepted')
        second = self.new('--linear-waiver', 'fixture')
        second['history'] = []
        tasks.save_task(self.root, second)
        self.assertEqual(self.update(second, 'cancelled')['task']['state'], 'cancelled')

    def test_audit_states_owner_parents_and_read_only(self):
        task = self.tracked()
        other = self.tracked('SH1-3', 'SH1-4')
        other['owner'] = 'another'; tasks.save_task(self.root, other)
        self.assertEqual(len(self.run_cli('linear-audit', '--owner', self.owner)['tasks']), 1)
        for ledger, expected in tasks.LINEAR_REQUIRED.items():
            task['state'] = ledger; task['linear']['state'] = None
            tasks.save_task(self.root, task)
            lag = self.run_cli('linear-audit', '--owner', self.owner)['tasks']
            self.assertEqual(lag[0]['required'], expected)
            self.state(task, expected)
            self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['tasks'], [])
        task['state'] = 'needs-user'; task['linear']['state'] = 'In Review'
        tasks.save_task(self.root, task)
        self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['tasks'], [])
        task['state'] = 'accepted'; task['linear']['state'] = 'Done'
        tasks.save_task(self.root, task)
        self.state(task, 'In Progress', parent=True)
        audit = self.run_cli('linear-audit', '--owner', self.owner)
        self.assertEqual(audit['parents'][0]['parent'], 'SH1-1')
        # A sibling belonging to another controller still holds the parent open.
        other['linear']['parent'] = 'SH1-1'; tasks.save_task(self.root, other)
        self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['parents'], [])
        other['state'] = 'cancelled'; other['linear']['state'] = 'Canceled'
        tasks.save_task(self.root, other)
        self.assertEqual(len(self.run_cli('linear-audit', '--owner', self.owner)['parents']), 1)
        self.state(task, 'Done', parent=True)
        self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['parents'], [])
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
                  for p in self.root.rglob('*') if p.is_file()}
        with patch.dict(os.environ, COS_STATE_DIR=str(self.root)), patch('builtins.print'):
            self.assertEqual(tasks.main(['linear-audit', '--owner', self.owner]), 0)
        after = {p: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
                 for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def git(self, path, *args):
        return subprocess.run(['git', '-C', str(path), *args], check=True, capture_output=True, text=True)

    def test_read_only_empty_state_directory(self):
        for root in (self.root, self.directory / 'absent'):
            with patch.dict(os.environ, COS_STATE_DIR=str(root)), patch('builtins.print') as output:
                self.assertEqual(tasks.main(['linear-audit', '--owner', self.owner]), 0)
                self.assertEqual(json.loads(output.call_args.args[0]), {'tasks': [], 'parents': []})
            self.assertFalse((root / '.lock').exists())
        self.assertFalse((self.directory / 'absent').exists())

    def test_mapping_and_offline(self):
        a = self.directory / 'a'; a.mkdir(); self.git(a, 'init')
        b = self.directory / 'b'; b.mkdir(); self.git(b, 'init')
        self.git(a, 'remote', 'add', 'origin', 'git@github.com:Org/Repo.git')
        self.git(b, 'remote', 'add', 'origin', 'https://github.com/org/repo.git')
        self.assertIsNone(self.run_cli('project-get', '--cwd', str(a))['mapping'])
        self.run_cli('project-set', '--cwd', str(a), '--team', 'SH1', '--project', 'setup', '--answered-by', 'Owner answer')
        mapped = self.run_cli('project-get', '--cwd', str(b))['mapping']
        self.assertEqual((mapped['team'], mapped['project']), ('SH1', 'setup'))
        self.assertEqual(mapped['answered_by'], 'Owner answer')
        self.assertTrue(mapped['answered_at'])
        self.git(b, 'remote', 'set-url', 'origin', 'ssh://git@github.com/Org/Repo.git')
        self.assertEqual(tasks.repository_key(a), tasks.repository_key(b))
        self.git(b, 'remote', 'remove', 'origin')
        fallback = tasks.repository_key(b)
        self.assertIsNone(self.run_cli('project-get', '--cwd', str(b))['mapping'])
        sub = b / 'nested'; sub.mkdir()
        self.assertEqual(tasks.repository_key(sub), fallback)
        self.assertTrue(fallback.startswith('local:'))
        # Deny network sockets and any subprocess other than local Git metadata reads.
        original = subprocess.run
        def local_git(argv, **kwargs):
            self.assertEqual(argv[0], 'git')
            self.assertIn(argv[3], ('remote', 'rev-parse'))
            if argv[3] == 'remote':
                self.assertTrue(len(argv) == 4 or argv[4:6] == ['get-url', 'origin'])
            return original(argv, **kwargs)
        with patch('socket.socket', side_effect=AssertionError('network forbidden')), \
             patch.object(tasks.subprocess, 'run', side_effect=local_git):
            self.run_cli('project-get', '--cwd', str(a))
            self.run_cli('project-set', '--cwd', str(a), '--team', 'SH1', '--project', 'new', '--answered-by', 'owner')
            task = self.tracked()
            self.state(task, 'Canceled')
            self.state(task, 'In Progress', parent=True)
            self.update(task, 'cancelled')
            self.run_cli('linear-audit', '--owner', self.owner)


if __name__ == '__main__':
    unittest.main()
