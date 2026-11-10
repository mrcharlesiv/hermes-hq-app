#!/usr/bin/env python3
"""Prints each UI test's result, its failure messages and its [measure] activities from an .xcresult bundle."""
import json, subprocess, sys

def tool(*args):
    out = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)

def cases(node):
    if node.get('nodeType') == 'Test Case':
        yield node
    for child in node.get('children') or []:
        yield from cases(child)

def measures(activities):
    for a in activities or []:
        if a.get('title', '').startswith('[measure] '):
            yield a['title'][len('[measure] '):]
        yield from measures(a.get('childActivities'))

path = sys.argv[1]
for root in tool('tests', '--path', path).get('testNodes', []):
    for case in cases(root):
        print(f"{case.get('name')}: {case.get('result')} ({case.get('duration')})")
        for child in case.get('children') or []:
            if child.get('nodeType') == 'Failure Message':
                print('    FAIL', child.get('name'))
        try:
            runs = tool('activities', '--path', path, '--test-id', case['nodeIdentifier']).get('testRuns', [])
            for run in runs:
                for text in measures(run.get('activities')):
                    print('    ', text)
        except Exception:
            pass
