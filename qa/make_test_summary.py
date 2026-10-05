#!/usr/bin/env python3
"""Turn Flutter JSON test events into auditable case-level CSV and totals."""
import collections
import csv
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
evidence = root / 'qa' / 'evidence'
suites, tests, outcomes = {}, {}, []
run_end = {}
for line in (evidence / 'tests-final.jsonl').read_text().splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = event.get('type')
    if kind == 'suite':
        suites[event['suite']['id']] = event['suite']
    elif kind == 'testStart':
        tests[event['test']['id']] = event['test']
    elif kind == 'testDone':
        outcomes.append(event)
    elif kind == 'done':
        run_end = event

rows = []
for outcome in outcomes:
    test = tests.get(outcome['testID'], {})
    name = test.get('name', '')
    if outcome.get('hidden') or name.startswith('loading ') or name.endswith(('(setUpAll)', '(tearDownAll)')):
        continue
    raw_path = suites.get(test.get('suiteID'), {}).get('path', '')
    path = str(Path(raw_path).relative_to(root)) if raw_path.startswith(str(root)) else raw_path
    status = 'SKIP' if outcome.get('skipped') else ('PASS' if outcome['result'] == 'success' else 'FAIL')
    rows.append({'case': len(rows) + 1, 'file': path, 'name': name, 'status': status, 'runner_result': outcome['result']})

csv_path = root.parent / 'QA_TEST_RESULTS.csv'
with csv_path.open('w', encoding='utf-8-sig', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=['case', 'file', 'name', 'status', 'runner_result'])
    writer.writeheader()
    writer.writerows(rows)

counts = dict(collections.Counter(row['status'] for row in rows))
by_file = {}
for row in rows:
    counts_for_file = by_file.setdefault(row['file'], collections.Counter())
    counts_for_file[row['status']] += 1
lf = lh = 0
lcov = root / 'coverage' / 'lcov.info'
if lcov.exists():
    for line in lcov.read_text().splitlines():
        if line.startswith('LF:'):
            lf += int(line[3:])
        elif line.startswith('LH:'):
            lh += int(line[3:])
summary = {
    'total_cases': len(rows), 'counts': counts,
    'by_file': {key: dict(value) for key, value in by_file.items()},
    'run_success': run_end.get('success'), 'runner_time_ms': run_end.get('time'),
    'line_coverage': {'hit': lh, 'found': lf, 'percent': round(lh * 100 / lf, 2) if lf else None},
    'failed_tests': [row['name'] for row in rows if row['status'] == 'FAIL'],
    'note': 'Blocked device/API/manual checks are not counted as automated passes.'
}
(evidence / 'test-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
if lcov.exists():
    (evidence / 'lcov.info').write_bytes(lcov.read_bytes())
print(json.dumps(summary, ensure_ascii=False, indent=2))
print(csv_path)
