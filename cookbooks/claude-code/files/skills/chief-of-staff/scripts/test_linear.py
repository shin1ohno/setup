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
        for ledger, expected in {'queued': 'Todo', 'starting': 'In Progress',
                                 'running': 'In Progress', 'retry': 'In Progress',
                                 'reviewing': 'In Review', 'accepted': 'Done',
                                 'cancelled': 'Canceled'}.items():
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

    def test_parent_close_gate_and_corrupt_closed_parent_audit(self):
        task = self.tracked()
        sibling = self.tracked('SH1-3')
        sibling['owner'] = 'another'; tasks.save_task(self.root, sibling)
        self.state(task, 'Canceled'); self.update(task, 'cancelled')
        self.state(task, 'In Progress', parent=True)
        before = (self.root / 'linear-parents.json').read_bytes()
        for close in ('Done', 'Canceled'):
            with self.assertRaisesRegex(ValueError, 'parent cannot close'):
                self.state(task, close, parent=True)
            self.assertEqual((self.root / 'linear-parents.json').read_bytes(), before)
            # Pre-existing/corrupt records must be audited even though the setter rejects them.
            tasks.save_records(self.root, 'linear-parents.json', {'sh1-1': {'state': close, 'history': []}})
            audit = self.run_cli('linear-audit', '--owner', self.owner)
            self.assertEqual(len(audit['parents']), 1)
            self.assertEqual(audit['parents'][0]['reason'], 'open-children')
            self.assertEqual(audit['parents'][0]['parent'], 'SH1-1')
            self.state(task, 'In Progress', parent=True)
            before = (self.root / 'linear-parents.json').read_bytes()
        self.state(sibling, 'Canceled'); self.update(sibling, 'cancelled')
        for close in ('Done', 'Canceled'):
            self.state(task, close, parent=True)
            self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['parents'], [])

    def test_parent_requires_both_ledger_and_matching_linear_closure(self):
        task = self.tracked()
        self.review_ready(task)
        self.state(task, 'In Review')
        self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['parents'], [])
        self.state(task, 'Done')
        self.state(task, 'In Progress', parent=True)
        self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['parents'], [])
        with self.assertRaisesRegex(ValueError, 'parent cannot close'):
            self.state(task, 'Done', parent=True)
        self.update(task, 'accepted')
        self.assertEqual(len(self.run_cli('linear-audit', '--owner', self.owner)['parents']), 1)
        self.state(task, 'Canceled')
        with self.assertRaisesRegex(ValueError, 'parent cannot close'):
            self.state(task, 'Done', parent=True)
        self.state(task, 'Done'); self.state(task, 'Done', parent=True)

    def test_waivers_visible_even_after_report_and_scoped_to_owner(self):
        task = self.new('--linear-waiver', 'Owner answer via question tool: skip this task')
        other = self.new('--linear-waiver', 'another owner')
        other['owner'] = 'another'; tasks.save_task(self.root, other)
        self.update(task, 'cancelled')
        self.mutate(task, 'reported', '--note', 'waiver and cancellation disclosed to owner')
        for command in ('list', 'linear-audit'):
            result = self.run_cli(command, '--owner', self.owner)
            self.assertEqual(len(result['waivers']), 1)
            waiver = result['waivers'][0]
            self.assertEqual(waiver['task_id'], task['id'])
            self.assertEqual(waiver['reason'], 'Owner answer via question tool: skip this task')
            self.assertEqual(waiver['at'], task['history'][0]['at'])
            self.assertEqual(waiver['state'], 'cancelled')
        with self.assertRaises(SystemExit):
            self.new('--linear-waiver', '   ')

    def test_needs_user_must_have_recorded_open_state(self):
        task = self.tracked()
        self.update(task, 'needs-user')
        for state in (None, 'Done', 'Canceled'):
            if state:
                self.state(task, state)
            audit = self.run_cli('linear-audit', '--owner', self.owner)
            self.assertEqual(len(audit['tasks']), 1)
            self.assertEqual(audit['tasks'][0]['required'], 'open')
        for state in ('Todo', 'In Progress', 'In Review'):
            self.state(task, state)
            self.assertEqual(self.run_cli('linear-audit', '--owner', self.owner)['tasks'], [])

    def test_identifiers_normalized_and_malformed_rejected(self):
        task = self.tracked('sh1-2', 'sh1-1')
        self.assertEqual(task['linear']['child'], 'SH1-2')
        self.assertEqual(task['linear']['parent'], 'SH1-1')
        # Older lowercase records must compare case-insensitively too.
        task['linear']['child'] = 'sh1-2'; task['linear']['parent'] = 'sh1-1'
        tasks.save_task(self.root, task)
        with self.assertRaisesRegex(ValueError, 'already belongs'):
            self.tracked('SH1-2')
        for bad in ('TBD', 'later', 'SH1-0', 'SH1-01', ' SH1-2', 'SH1-2 ',
                    '00000000-0000-0000-0000-000000000000'):
            with self.assertRaisesRegex(ValueError, 'identifier must'):
                self.tracked(bad)
            with self.assertRaisesRegex(ValueError, 'identifier must'):
                self.tracked('SH1-9', bad)
        self.state(task, 'Canceled'); self.update(task, 'cancelled')
        self.state(task, 'Canceled', parent=True)
        self.assertIn('SH1-1', tasks.read_records(self.root, 'linear-parents.json'))

    def test_identifier_roles_and_self_parent(self):
        with self.assertRaisesRegex(ValueError, 'must differ'):
            self.tracked('sh1-1', 'SH1-1')
        self.tracked()
        for child, parent in [('SH1-3', 'sh1-2'), ('sh1-1', 'SH1-3')]:
            with self.assertRaisesRegex(ValueError, 'roles must not overlap'):
                self.tracked(child, parent)

    def test_mapping_distinct_paths_defaults_suffix_and_history(self):
        repo = self.directory / 'repo'; repo.mkdir(); self.git(repo, 'init')
        self.git(repo, 'remote', 'add', 'origin', 'git@nas:repos/x.git')
        def key(remote):
            self.git(repo, 'remote', 'set-url', 'origin', remote)
            return tasks.repository_key(repo)
        self.assertNotEqual(key('git@nas:repos/x.git'), key('ssh://git@nas/repos/x.git'))
        self.assertNotEqual(key('git@nas:repos/x.git'), key('other@nas:repos/x.git'))
        self.assertEqual(key('git@nas:/repos/x.git'), key('ssh://git@nas:22/repos/x.git'))
        canonical = key('https://github.com/Org/Repo')
        for remote in ('https://github.com/Org/Repo.git', 'https://github.com:443/org/repo',
                       'http://github.com:80/org/repo', 'ssh://git@github.com:22/Org/Repo.git',
                       'git@github.com:org/repo.git'):
            self.assertEqual(key(remote), canonical)
        self.assertNotEqual(key('ssh://git@github.com:443/org/repo.git'), canonical)
        self.assertNotEqual(key('http://github.com:22/org/repo.git'), canonical)
        key('../upstream.git')
        top = tasks.repository_key(repo)
        sub = repo / 'sub'; sub.mkdir()
        self.assertEqual(top, tasks.repository_key(sub))
        second = self.directory / 'second'; second.mkdir(); self.git(second, 'init')
        self.git(second, 'remote', 'add', 'origin', '../upstream.git')
        self.assertEqual(top, tasks.repository_key(second))
        self.run_cli('project-set', '--cwd', str(repo), '--team', 'SH1', '--project', 'first', '--answered-by', 'answer-1')
        self.run_cli('project-set', '--cwd', str(sub), '--team', 'SH1', '--project', 'second', '--answered-by', 'answer-2')
        mapping = self.run_cli('project-get', '--cwd', str(second))['mapping']
        self.assertEqual(mapping['project'], 'second')
        self.assertEqual([r['project'] for r in mapping['history']], ['first', 'second'])
        self.assertEqual([r['answered_by'] for r in mapping['history']], ['answer-1', 'answer-2'])
        self.assertTrue(all(r['answered_at'] for r in mapping['history']))

    def git(self, path, *args):
        return subprocess.run(['git', '-C', str(path), *args], check=True, capture_output=True, text=True)

    def test_read_only_empty_state_directory(self):
        for root in (self.root, self.directory / 'absent'):
            with patch.dict(os.environ, COS_STATE_DIR=str(root)), patch('builtins.print') as output:
                self.assertEqual(tasks.main(['linear-audit', '--owner', self.owner]), 0)
                self.assertEqual(json.loads(output.call_args.args[0]), {'tasks': [], 'parents': [], 'waivers': []})
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
