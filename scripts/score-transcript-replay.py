#!/usr/bin/env python3
"""Score replay JSON against an offline JSON/text reference; no source files are modified.

Usage: score-transcript-replay.py --reference offline.json replay.json ...
Normalized word recall counts correctly aligned reference words / reference words.
WER is (substitutions + deletions + insertions) / reference words. The offline
reference is a recognizer output, not human-labelled ground truth.
"""
import argparse
import json
import re
from pathlib import Path


def tokens(text):
    return re.findall(r"[\w]+(?:['’][\w]+)*", text.lower())


def score(reference, hypothesis):
    a, b = tokens(reference), tokens(hypothesis)
    # Each cell carries (edit cost, matched words, substitutions, deletions, insertions).
    last = [(j, 0, 0, 0, j) for j in range(len(b) + 1)]
    for i, x in enumerate(a, 1):
        row = [(i, 0, 0, i, 0)]
        for j, y in enumerate(b, 1):
            p = last[j - 1]
            diagonal = (p[0] + (x != y), p[1] + (x == y), p[2] + (x != y), p[3], p[4])
            p, q = last[j], row[j - 1]
            row.append(min([diagonal, (p[0] + 1, p[1], p[2], p[3] + 1, p[4]),
                            (q[0] + 1, q[1], q[2], q[3], q[4] + 1)], key=lambda v: (v[0], -v[1])))
        last = row
    edits, matches, substitutions, deletions, insertions = last[-1]
    return dict(reference_words=len(a), hypothesis_words=len(b), matches=matches,
                substitutions=substitutions, deletions=deletions, insertions=insertions,
                recall=matches / max(1, len(a)), wer=edits / max(1, len(a)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('replays', nargs='+', type=Path)
    args = parser.parse_args()
    raw = args.reference.read_text()
    try:
        ref = json.loads(raw)
        reference = ref.get('text', ref.get('parsed_text', ref.get('transcript', '')))
    except json.JSONDecodeError:
        reference = raw
    results = []
    for path in args.replays:
        replay = json.loads(path.read_text())
        finals = [e for e in replay['events'] if e['type'].endswith('.completed')]
        legacy = ' '.join(' '.join(w['word'] for w in e.get('words', []) if isinstance(w.get('start'), (int, float)) and isinstance(w.get('end'), (int, float))) or e.get('transcript', '') for e in finals)
        results.append(dict(file=str(path), audio_exactly_once=replay['audio_exactly_once'],
                            peak_backlog_seconds=replay['peak_backlog_seconds'],
                            hidden_partials=replay['hidden_partials'],
                            recognizer=score(reference, replay['recognizer_text']),
                            old_parser=score(reference, legacy), fixed_parser=score(reference, replay['parsed_text']),
                            final_text_disagreements=sum(e['transcript'].split() != [w['word'] for w in e.get('words', [])] for e in finals)))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
