#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import contextlib
import io
import json
import tempfile

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

    def test_resumed_session_exact_unique_foreground_only(self):
        sid = '01a1a8c6-8ab3-7783-bb82-58414c021a97'
        info = lambda _: {'foreground_processes': [
            {'pid': 42, 'argv': ['/bin/codex', 'resume', sid]}]}
        self.assertEqual(m.resumed_session([self.p], sid, info), (self.p, (42,)))
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            m.resumed_session([self.p, dict(self.p, pane_id='w1:p2')], sid, info)
        for argv in [['codex'], ['codex', 'resume', '--last'],
                     ['codex', 'resume', sid + '0'], ['codex', '--config', sid],
                     ['sh', 'resume', sid], ['codex', 'resume', '--model', sid]]:
            wrong = lambda _, argv=argv: {'foreground_processes': [{'pid': 42, 'argv': argv}]}
            self.assertIsNone(m.resumed_session([self.p], sid, wrong))
        self.assertIsNone(m.resumed_session([self.p], 'invalid', info))
        self.assertIsNone(m.resumed_session([dict(self.p, agent='claude')], sid, info))

    def test_daemon_resume_resolve_rechecks_identity_without_visual_proof(self):
        sid = '01a1a8c6-8ab3-7783-bb82-58414c021a97'
        pane = dict(self.p, session='test')
        info = {'foreground_processes': [{'pid': 42, 'argv': ['codex', 'resume', sid]}]}
        with patch.object(m, 'inventory', return_value=[pane]), patch.object(m, 'ancestors', return_value={99}), patch.dict(m.os.environ, {'CODEX_SESSION_ID': sid}, clear=True), patch('sys.argv', ['caller', 'resolve']):
            output = io.StringIO()
            with patch.object(m, 'process', return_value=info), contextlib.redirect_stdout(output):
                m.main()
            self.assertEqual(json.loads(output.getvalue())['method'], 'foreground-resume-session')
            replaced = {'foreground_processes': [{'pid': 43, 'argv': ['codex', 'resume', sid]}]}
            with patch.object(m, 'process', side_effect=[info, replaced]):
                with self.assertRaisesRegex(ValueError, 'caller changed'):
                    m.main()
            changed = {'foreground_processes': [{'pid': 42, 'argv': ['codex', 'resume', 'other']}]}
            with patch.object(m, 'process', side_effect=[info, changed]):
                with self.assertRaisesRegex(ValueError, 'caller session changed'):
                    m.main()
    def test_challenge_rejects_absent_ambiguous_stale_unrelated_replaced(self):
        match = lambda panes, state, sid, now, read, info=self.info: m.challenge_match(panes, state, sid, now, read, info)
        self.assertEqual(match([self.p], self.state, 'session', 110, lambda _: 'proof')[0], self.p)
        for panes, sid, now, read, info in [([], 'session', 110, lambda _: '', self.info), ([self.p, self.p], 'session', 110, lambda _: 'proof', self.info), ([self.p], 'other', 110, lambda _: 'proof', self.info), ([self.p], 'session', 221, lambda _: 'proof', self.info), ([self.p], 'session', 110, lambda _: 'proof', lambda _: {'foreground_processes': [{'pid': 43, 'argv': ['codex']}]})]:
            with self.assertRaises(ValueError): match(panes, self.state, sid, now, read, info)

    def test_prepare_requires_live_codex_foreground(self):
        for panes, info in [([], self.info), ([self.p], lambda _: {'foreground_processes': []}),
                            ([self.p], lambda _: {'foreground_processes': [{'pid': 42, 'argv': ['zsh']}]})]:
            with tempfile.TemporaryDirectory() as tmp, patch.object(m, 'state_path', return_value=Path(tmp) / 'proof.json'), patch.object(m, 'inventory', return_value=panes), patch.object(m, 'process', side_effect=info), patch('sys.argv', ['caller', 'prepare']):
                with self.assertRaisesRegex(ValueError, 'no live Codex foreground pane'):
                    m.main()

    def test_visual_proof_survives_tui_hard_wraps(self):
        state = dict(self.state, marker='HERDR-CALLER-PROOF-0123456789abcdef')
        wrapped = '  HERDR-CALLER-PROOF-\n  0123456789abcdef\n'
        self.assertEqual(m.challenge_match([self.p], state, 'session', 110,
                                          lambda _: wrapped, self.info)[0], self.p)
        with self.assertRaisesRegex(ValueError, 'absent or ambiguous'):
            m.challenge_match([self.p], state, 'session', 110,
                              lambda _: wrapped.replace('a', 'b'), self.info)

    def test_daemon_visual_proof_without_inherited_environment(self):
        # The daemon has no HERDR_* or terminal ancestry. Only commentary is
        # visible in the client; raw tool stdout is not a display guarantee.
        pane = dict(self.p, session='test')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'proof.json'
            with patch.object(m, 'state_path', return_value=path), patch.object(m, 'inventory', return_value=[pane]), patch.object(m, 'process', side_effect=self.info), patch.dict(m.os.environ, {'CODEX_SESSION_ID': 'session'}, clear=True):
                output = io.StringIO()
                with patch('sys.argv', ['caller', 'prepare']), contextlib.redirect_stdout(output):
                    m.main()
                state = json.loads(path.read_text())
                self.assertIn('assistant commentary BEFORE verify', output.getvalue())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                with patch('sys.argv', ['caller', 'verify']), patch.object(m, 'run', return_value='tool output collapsed'):
                    with self.assertRaisesRegex(ValueError, 'absent or ambiguous'):
                        m.main()
                self.assertTrue(path.exists())
                output = io.StringIO()
                with patch('sys.argv', ['caller', 'verify']), patch.object(m, 'run', return_value=state['marker']), contextlib.redirect_stdout(output):
                    m.main()
                self.assertEqual(json.loads(output.getvalue())['pane_id'], pane['pane_id'])
                self.assertFalse(path.exists())

if __name__ == '__main__': unittest.main()
