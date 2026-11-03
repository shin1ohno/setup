#!/usr/bin/env python3
from pathlib import Path
import importlib.util
import unittest
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('compose', Path(__file__).with_name('compose-skill.py'))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)
class PolicyTest(unittest.TestCase):
    def test_delegation_precedes_investigation_and_fresh_agent(self):
        skill = (root / 'cookbooks/claude-code/files/skills/chief-of-staff/SKILL.md').read_text()
        for text in ('Do not investigate the task repository,', 'or implement the task before a worker receives the brief.', 'start\na fresh agent', 'never reuse a previous worker', 'Controller review after delivery remains allowed'):
            self.assertIn(text, skill)
        dispatch = (root / 'cookbooks/claude-code/files/skills/chief-of-staff/references/dispatch.md').read_text()
        self.assertIn('Unless the user requests a new agent or separate pane', dispatch)
    def test_composition_replaces_unsafe_gate(self):
        import subprocess
        upstream = subprocess.check_output(['herdr', '--skill'], text=True)
        rendered = compose.compose(upstream, '')
        self.assertIn('caller-context.py resolve', rendered)
        self.assertNotIn('test "${HERDR_ENV:-}" = 1', rendered)
        self.assertNotIn('herdr pane split --current', rendered)
        self.assertIn('never infer caller identity from focus', rendered)
if __name__ == '__main__': unittest.main()
