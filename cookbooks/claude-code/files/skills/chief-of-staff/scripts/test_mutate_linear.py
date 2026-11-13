#!/usr/bin/env python3
"""Repository-only mutation evidence; output and all fake ledgers stay under --output."""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys

GATES = [
    ('new-identifiers-or-waiver', 'new requires Linear child and parent or an explicit owner waiver', 'test_new_gate'),
    ('accepted-needs-done', 'Linear Done must be recorded before accepted', 'test_accepted_gate'),
    ('cancelled-needs-canceled', 'Linear Canceled must be recorded before cancelled', 'test_cancelled_gate'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('tasks.py').read_text()
    tests = Path(__file__).with_name('test_linear.py').read_text()

    def execute(name, code, test=None):
        directory = args.output / name
        directory.mkdir()
        (directory / 'tasks.py').write_text(code)
        (directory / 'test_linear.py').write_text(tests)
        temp = directory / 'tmp'; temp.mkdir()
        env = dict(os.environ, TMPDIR=str(temp), PYTHONDONTWRITEBYTECODE='1',
                   COS_STATE_DIR=str(directory / 'unused-state'))
        result = subprocess.run([sys.executable, '-m', 'unittest', '-v',
                                 'test_linear' + ('.LinearTest.' + test if test else '')],
                                cwd=directory, env=env, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        (args.output / (name + '.txt')).write_text(output)
        return result.returncode, output

    code, _ = execute('baseline', source)
    if code:
        raise RuntimeError('baseline failed')
    results = []
    for name, error, test in GATES:
        tree = ast.parse(source)
        matches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                   and any(isinstance(child, ast.Raise) and error in ast.unparse(child)
                           for child in node.body)]
        if len(matches) != 1:
            raise RuntimeError('gate not uniquely identified: ' + name)
        node = matches[0]
        original = ast.get_source_segment(source, node.test)
        # Replace only this condition, retaining syntactic validity and all other gates.
        lines = source.splitlines(keepends=True)
        start = sum(map(len, lines[:node.test.lineno - 1])) + node.test.col_offset
        end = sum(map(len, lines[:node.test.end_lineno - 1])) + node.test.end_col_offset
        mutated = source[:start] + 'False' + source[end:]
        ast.parse(mutated)
        code, output = execute(name, mutated, test)
        killed = code != 0 and 'AssertionError: ValueError not raised' in output and 'ERROR:' not in output
        results.append(dict(gate=name, mutation=original + ' -> False', test=test,
                            killed=killed, exit_code=code))
    (args.output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    for result in results:
        print(result['gate'], 'KILLED' if result['killed'] else 'SURVIVED/INVALID')
    return 0 if all(result['killed'] for result in results) else 1


if __name__ == '__main__':
    sys.exit(main())
