#!/usr/bin/env python3
"""Make a disposable Markdown backlog from synthetic vault fixtures; never use real notes."""
import argparse
import json
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('output', type=Path)
p.add_argument('--copies', type=int, default=100)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
notes = {}
for line in Path(__file__).resolve().parents[1].joinpath('fixtures/retrieval-vault.jsonl').read_text().splitlines():
    for note in json.loads(line).get('vault', []):
        notes[note['id']] = note
for i in range(a.copies):
    for id, note in notes.items():
        a.output.joinpath(f'{id}-{i:04}.md').write_text(note['markdown'])
print(f'{len(notes) * a.copies} notes in {a.output}')
