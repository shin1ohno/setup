#!/usr/bin/env python3
"""Remove one lifecycle guard at a time; require its regression test to fail.

Usage: python3 mutate_pane_lifecycle.py --output /absolute/private/evidence
Copies only tasks.py and its standalone test module into output-owned folders.
Never operates on a real ledger or Herdr server.
"""
import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys

# (review gate, function, expression to disable, focused regression test)
GATES = [
    ('M01', 'closable', 'task.get("owner", "").rpartition("#")[0] != socket', 'test_each_independent_inventory_gate'),
    ('M02', 'closable', 'pane_id in controllers', 'test_each_independent_inventory_gate'),
    ('M03', 'closable', 'pane_id == caller', 'test_each_independent_inventory_gate'),
    ('M04', 'closable', 'agent.get("name") != record["agent"]', 'test_positive_and_each_gate_mutation'),
    ('M05', 'closable', '("socket: " + socket) not in status.splitlines()', 'test_inventory_failure_and_wrong_socket_fail_closed'),
    ('M06', 'closable', 'caller not in panes', 'test_inventory_failure_and_wrong_socket_fail_closed'),
    ('M07', 'closable', 'not re.fullmatch(pane_pattern, owner.rpartition("#")[2])', 'test_positive_and_each_gate_mutation'),
    ('M08', 'closable', 'pane["pane_id"] in panes', 'test_each_independent_inventory_gate'),
    ('M09', 'run', 'attempt.get("resume_session") and attempt["resume_session"] != session', 'test_resume_snapshot_new_pane_and_identity_guards'),
    ('M10', 'run', 'args.launch_options is not None and options != previous.get("launch_options", [])', 'test_hc_path_resume_guards_and_unknown_profile'),
    ('M11', 'run', 'previous_profile is not None and previous_profile != args.profile', 'test_resume_snapshot_new_pane_and_identity_guards'),
    ('M12', 'run', 'model_matches(args.model, previous.get("observed_model")) and previous.get("observed_effort") == args.effort', 'test_hc_path_resume_guards_and_unknown_profile'),
    ('M13', 'run', 'not session or not re.fullmatch(UUID, session)', 'test_hc_path_resume_guards_and_unknown_profile'),
    ('M14', 'run', 'args.pane == task["owner"].rpartition("#")[2] or args.pane == attempt.get("pane")', 'test_helper_cannot_claim_existing_pane_or_controller'),
    ('M15-terminal', 'closable', 'pane.get("terminal_id") != terminal_id', 'test_each_independent_inventory_gate'),
    ('M15-status', 'closable', 'pane.get("agent_status") not in {"idle", "done"}', 'test_each_independent_inventory_gate'),
    ('M15-kind', 'closable', 'pane.get("agent") != record.get("kind")', 'test_each_independent_inventory_gate'),
    ('M16-terminal', 'closable', 'agent.get("terminal_id") != terminal_id', 'test_each_independent_inventory_gate'),
    ('M16-status', 'closable', 'agent.get("agent_status") not in {"idle", "done"}', 'test_each_independent_inventory_gate'),
    ('M16-kind', 'closable', 'agent.get("agent") != record.get("kind")', 'test_each_independent_inventory_gate'),
    ('M17', 'run', 'previous.get("launch_plan")', 'test_resume_snapshot_new_pane_and_identity_guards'),
    ('M18', 'run', 'args.kind != "shell" and not args.agent_name', 'test_helper_cannot_claim_existing_pane_or_controller'),
    ('M19', 'closable', 'task["state"] == "reviewing" and not task.get("envelope_receipt")', 'test_positive_and_each_gate_mutation'),
    ('M20', 'closable', 'attempt.get("route", "herdr") not in {"herdr", "herdr1"}', 'test_positive_and_each_gate_mutation'),
    ('M21', 'closable', 'not task.get("worker_settled")', 'test_missing_observation_and_supervision_pause'),
    ('M22', 'closable', 'owner != args.owner and owner.rpartition("#")[2] in panes', 'test_orphan_is_absent_owner_not_idle_owner'),
    ('M23', 'closable', 'task.get("state") not in {"reviewing", "needs-user", "accepted", "cancelled"}', 'test_positive_and_each_gate_mutation'),
    ('M24', 'closable', 'record is not attempt and not record.get("creation_receipt")', 'test_helper_cannot_claim_existing_pane_or_controller'),
    ('M25', 'run', 'not helper or not helper.get("creation_receipt") or helper["terminal_id"] != args.terminal_id', 'test_helper_cannot_claim_existing_pane_or_controller'),
    ('M26', 'run', 'attempt.get("route") == "hc"', 'test_hc_path_resume_guards_and_unknown_profile'),
]


def mutated(source, gate):
    name, function, expression, _ = gate
    tree = ast.parse(source)
    target = ast.dump(ast.parse(expression, mode='eval').body, include_attributes=False)
    count = 0
    class Replace(ast.NodeTransformer):
        def visit(self, node):
            nonlocal count
            if name == 'M17':
                # Change only snapshot inheritance, not profile derivation.
                if (isinstance(node, ast.Assign) and len(node.targets) == 1
                        and ast.unparse(node.targets[0]) == "attempt['launch_plan']"
                        and ast.dump(node.value, include_attributes=False) == target):
                    count += 1
                    node.value = ast.parse('json.loads(Path(previous["plan"]).read_text())', mode='eval').body
                    return node
                return super().visit(node)
            if ast.dump(node, include_attributes=False) == target:
                count += 1
                replacement = ast.Constant(name == 'M12')
                return ast.copy_location(replacement, node)
            return super().visit(node)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == function:
            Replace().visit(node)
    expected = 1
    if count != expected:
        raise ValueError(f'{name}: expected {expected} expression matches, found {count}')
    return ast.unparse(ast.fix_missing_locations(tree))+'\n'


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--output', required=True, type=Path)
    args=cli.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source=Path(__file__).with_name('tasks.py').read_text()
    tests=Path(__file__).with_name('test_pane_lifecycle.py').read_text()
    def execute(name, code, test=None):
        directory=args.output/name
        directory.mkdir()
        (directory/'tasks.py').write_text(code)
        (directory/'test_pane_lifecycle.py').write_text(tests)
        temp=directory/'tmp';temp.mkdir()
        env=dict(os.environ,TMPDIR=str(temp),PYTHONDONTWRITEBYTECODE='1',COS_STATE_DIR=str(directory/'unused-state'))
        command=[sys.executable,'-m','unittest','-v','test_pane_lifecycle'+('.LifecycleTest.'+test if test else '')]
        result=subprocess.run(command,cwd=directory,env=env,text=True,capture_output=True,timeout=120)
        output=result.stdout+result.stderr
        (args.output/(name+'.txt')).write_text(output)
        return result.returncode, output
    code, output=execute('baseline',source)
    if code: raise RuntimeError('baseline failed; mutations cannot be interpreted')
    def check(gate):
        code, output=execute(gate[0],mutated(source,gate),gate[3])
        killed=code!=0 and 'FAILED (' in output and not any(
            text in output for text in ('ImportError:', 'SyntaxError:', 'ModuleNotFoundError:', 'FileNotFoundError:'))
        return dict(gate=gate[0],test=gate[3],killed=killed,exit_code=code)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(check,GATES))
    (args.output/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
    for result in results: print(result['gate'], 'KILLED' if result['killed'] else 'SURVIVED/INVALID')
    return 0 if all(result['killed'] for result in results) else 1

if __name__ == '__main__': sys.exit(main())
