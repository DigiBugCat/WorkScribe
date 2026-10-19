#!/usr/bin/env python3
"""Choose replay arms on other cases only; report the held-out result, never an in-sample winner."""
import argparse
import json
from pathlib import Path


def utility(rows):
    return sum((not r['abstain'] and r['converged'] and r['faithful'])
               - 2*r['unfaithful'] + (r['abstain'] and r['quiet']) for r in rows)


def fit(arms):
    identities=[{(r['case_id'],r['note_id']) for r in arm['jots']} for arm in arms.values()]
    if not identities or not identities[0] or any(i != identities[0] for i in identities):
        raise ValueError('All arms must contain exactly the same nonempty cases and jots')
    if any(r['converged'] is None and not r['abstain'] or r['faithful'] is None
           for arm in arms.values() for r in arm['jots']):
        raise ValueError('Reviewed anchors and completed faithfulness judgments are required')
    cases=sorted({case for case,_ in identities[0]})
    if len(cases)<2: raise ValueError('Need at least two cases for held-out selection')
    folds=[]
    for case in cases:
        def training(name):
            rows=[r for r in arms[name]['jots'] if r['case_id'] != case]
            return utility(rows)/(len(cases)-1)
        # Same deterministic tie rule as the old LOCO selector; held-out rows never vote.
        winner=sorted(arms, key=lambda name:(-training(name),name))[0]
        held=[r for r in arms[winner]['jots'] if r['case_id']==case]
        folds.append(dict(held_out=case,arm=winner,training_score=training(winner),score=utility(held)))
    return dict(split='leave-one-case-out',folds=folds,mean=sum(f['score'] for f in folds)/len(folds))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('reports',nargs='+',help='ARM=path/to/replay/report.json')
    p.add_argument('--out',required=True)
    a=p.parse_args()
    arms={name:json.loads(Path(path).read_text()) for name,path in (s.split('=',1) for s in a.reports)}
    Path(a.out).write_text(json.dumps(fit(arms),indent=2)+'\n')

if __name__=='__main__': main()
