#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('caller', Path(__file__).with_name('caller-context.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class CallerTest(unittest.TestCase):
    def setUp(self):
        self.p = dict(socket='s', pane_id='w1:p1', workspace_id='w1', tab_id='w1:t1', agent='codex')
        self.info = lambda p: {'foreground_processes': [{'pid': 42, 'argv': ['codex']}]}
        self.state = dict(session_id='session', created=100, marker='proof', processes={'s#w1:p1': [42]})
    def test_inherited_requires_real_ancestry(self):
        env = dict(HERDR_ENV='1', HERDR_PANE_ID='w1:p1', HERDR_WORKSPACE_ID='w1')
        self.assertEqual(m.inherited([self.p], env, {42}, self.info), self.p)
        self.assertIsNone(m.inherited([self.p], env, {43}, self.info))
        self.assertIsNone(m.inherited([self.p], {}, {42}, self.info))
        with self.assertRaises(ValueError): m.inherited([self.p, self.p], env, {42}, self.info)
    def test_challenge_rejects_absent_ambiguous_stale_unrelated_replaced(self):
        match = lambda panes, state, sid, now, read, info=self.info: m.challenge_match(panes, state, sid, now, read, info)
        self.assertEqual(match([self.p], self.state, 'session', 110, lambda _: 'proof')[0], self.p)
        for panes, sid, now, read, info in [([], 'session', 110, lambda _: '', self.info), ([self.p, self.p], 'session', 110, lambda _: 'proof', self.info), ([self.p], 'other', 110, lambda _: 'proof', self.info), ([self.p], 'session', 221, lambda _: 'proof', self.info), ([self.p], 'session', 110, lambda _: 'proof', lambda _: {'foreground_processes': [{'pid': 43, 'argv': ['codex']}]})]:
            with self.assertRaises(ValueError): match(panes, self.state, sid, now, read, info)

if __name__ == '__main__': unittest.main()
