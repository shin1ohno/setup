#!/usr/bin/env python3
"""Remove one lifecycle guard at a time; require the full CI suite to fail.

Usage: python3 test_mutate_pane_lifecycle.py --output /absolute/private/evidence
Copies the whole skill and runs the same unittest discovery as CI for every mutant.
Set TMPDIR to a short writable directory for AF_UNIX tests.
Never operates on a real ledger or Herdr server.
"""
import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
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
    ('X12-terminal-missing', 'closable', 'not terminal_id', 'full discovery'),
    ('X15-needsuser-reset', 'run', 'args.state == "needs-user"', 'full discovery'),
    ('X18-helperopen-socket', 'run', '"socket: " + task["owner"].rpartition("#")[0] not in status.splitlines()', 'full discovery'),
    ('X19-helperopen-state', 'run', 'task["state"] not in {"starting", "running"}', 'full discovery'),
    ('X22-settle-state', 'run', 'task["state"] not in {"needs-user", "cancelled"}', 'full discovery'),
    ('X23-launch-harness', 'run', 'plan.get("harness") != attempt["kind"]', 'full discovery'),
    ('X24-launch-ready', 'run', 'not plan.get("launch_ready")', 'full discovery'),
    ('X16-attempt-pop-settled', 'run', 'task.pop("worker_settled", None)', 'full discovery'),
    ('E03-read-only-lock', 'main', 'args.command == "closable" and not args.adopt', 'full discovery'),
    ('N1-budget-reset', 'run', 'args.state == "retry" and len(task["attempts"]) >= task["max_attempts"]', 'full discovery'),
    ('N3-plan-harness', 'run', 'launch.get("harness") != args.kind', 'full discovery'),
    ('N3-plan-ready', 'run', 'not launch.get("launch_ready")', 'full discovery'),
]


def mutated(source, gate):
    name, function, expression, _ = gate
    tree = ast.parse(source)
    target = ast.dump(ast.parse(expression, mode='eval').body, include_attributes=False)
    count = 0
    class Replace(ast.NodeTransformer):
        def visit_Expr(self, node):
            nonlocal count
            if name == "X16-attempt-pop-settled" and ast.dump(node.value, include_attributes=False) == target:
                count += 1
                return ast.copy_location(ast.Pass(), node)
            return self.generic_visit(node)

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
            if name != 'X16-attempt-pop-settled' and ast.dump(node, include_attributes=False) == target:
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
    skill=Path(__file__).resolve().parents[1]
    def execute(name, code, test=None):
        directory=args.output/name
        shutil.copytree(skill, directory/'chief-of-staff', ignore=shutil.ignore_patterns('__pycache__'))
        scripts=directory/'chief-of-staff'/'scripts'
        (scripts/'tasks.py').write_text(code)
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',COS_STATE_DIR=str(directory/'unused-state'))
        command=[sys.executable,'-m','unittest','discover','-s',str(scripts),'-p','test_*.py']
        result=subprocess.run(command,cwd=directory,env=env,text=True,capture_output=True,timeout=1500)
        output=result.stdout+result.stderr
        (args.output/(name+'.txt')).write_text(output)
        return result.returncode, output
    code, output=execute('baseline',source)
    if code: raise RuntimeError('baseline failed; mutations cannot be interpreted')
    def check(gate):
        code, output=execute(gate[0],mutated(source,gate),gate[3])
        killed=code!=0 and 'FAILED (' in output and not any(
            text in output for text in ('ImportError:', 'SyntaxError:', 'ModuleNotFoundError:', 'FileNotFoundError:'))
        return dict(gate=gate[0],suite='unittest discover -p test_*.py',killed=killed,exit_code=code)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(check,GATES))
    (args.output/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
    for result in results: print(result['gate'], 'KILLED' if result['killed'] else 'SURVIVED/INVALID')
    return 0 if all(result['killed'] for result in results) else 1

if __name__ == '__main__': sys.exit(main())
