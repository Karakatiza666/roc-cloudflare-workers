#!/usr/bin/env python3
# PLAN.md 11c: the ledger of the edge run (edge/ledger.md).
#   edge/ledger.py add <kind> <name> <id>     a row in the table "Created", with the time (UTC)
#   edge/ledger.py del <name>                 the time of the delete in the row of <name>
import datetime, pathlib, sys

path = pathlib.Path(__file__).with_name('ledger.md')
now = datetime.datetime.now(datetime.timezone.utc).strftime('%H:%M:%S')
text = path.read_text()
head, tail = text.split('\n## End state', 1)
if sys.argv[1] == 'add':
    kind, name, ident = sys.argv[2:5]
    if not name.startswith('rocplat-test-'):
        sys.exit(f'refused: {name} does not start with rocplat-test-')
    head = head.rstrip('\n') + f'\n| {now} | {kind} | `{name}` | {ident} | |\n'
elif sys.argv[1] == 'del':
    name = sys.argv[2]
    lines = head.split('\n')
    for i, line in enumerate(lines):
        if f'| `{name}` |' in line and line.endswith('| |'):
            lines[i] = line[:-2] + f' {now} |'
    head = '\n'.join(lines)
path.write_text(head.rstrip('\n') + '\n\n## End state' + tail)
