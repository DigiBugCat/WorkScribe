#!/usr/bin/env python3
"""Timeline tooling: convert cases, emit blind faithfulness packets, consume judgments.
No model is called here. Run WorkScribe --replay between convert and report.
"""
import argparse
import hashlib
import json
import random
import re
from pathlib import Path


def read(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + '\n')


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def convert(inputs, output, milestone_path=None):
    """Merge vault enrichments by ID, keeping the reviewed input's transcript and rubric.

    Prose requirements remain prose. They are never silently interpreted as regexes.
    Converted milestones expose the evidence frontier for human temporal review; only
    explicitly authored regex anchors are used as deterministic assertions.
    """
    cases = {}
    for path in inputs:
        for source in read(path):
            if source['id'] in cases:
                old = cases[source['id']]
                if source.get('vault'):
                    old['vault'] = source['vault']
                    for g in source.get('gold_lines', []):
                        if g.get('background_note_ids'):
                            old['gold'][g['note_id']]['background_note_ids'] = g['background_note_ids']
                continue
            if 'speech' in source:
                cases[source['id']] = source
                continue
            speech = [dict(s, final_at=s.get('final_at', s['end'] + .5)) for s in source['segments']]
            last = max([s['final_at'] for s in speech] + [n['at'] for n in source['notes']] + [0])
            gold = {}
            for g in source['gold_lines']:
                evidence = g['evidence_segment_ids']
                # Every cited frontier is inspectable. No earlier checkpoint receives final facts.
                milestones = [dict(after=s['id'], must=[], must_not=[], review_required=True)
                              for s in speech if s['id'] in evidence]
                if not milestones:
                    milestones = [dict(at=last, must=[], must_not=[], review_required=True)]
                gold[g['note_id']] = dict(abstain=g['abstain'], evidence=evidence,
                    milestones=milestones, final=dict(must=[], must_not=[],
                    semantic_must=g.get('must_include', []), semantic_must_not=g.get('must_not', []),
                    review_required=True), background_note_ids=g.get('background_note_ids', []))
            cases[source['id']] = dict(id=source['id'], title=source.get('title', source['id']),
                status=source['status'], speech=speech, jots=source['notes'], stop_at=last + 1,
                retractions=[], vault=source.get('vault', []), gold=gold,
                description=source.get('description', ''), conversion=dict(version=1,
                    source_sha256=sha(source), milestone_policy='evidence frontiers; prose gold preserved for review'))
    if milestone_path:
        overrides = json.loads(Path(milestone_path).read_text())
        for cid, notes in overrides.items():
            if cid not in cases:
                continue
            for nid, milestones in notes.items():
                for m in milestones:
                    if 'after' in m and m['after'] not in {s['id'] for s in cases[cid]['speech']}:
                        raise ValueError(f'Unknown milestone segment {cid}/{m["after"]}')
                    for pattern in m.get('must', []) + m.get('must_not', []): re.compile(pattern)
                cases[cid]['gold'][nid]['milestones'] = milestones
    Path(output).write_text(''.join(json.dumps(c, sort_keys=True, ensure_ascii=False) + '\n' for c in cases.values()))
    return list(cases.values())


def anchors(text, spec):
    return all(re.search(p, text, re.I) for p in spec.get('must', [])) and not any(
        re.search(p, text, re.I) for p in spec.get('must_not', []))


def facts(text):
    # A diagnostic for churn, never a semantic truth classifier.
    return sorted(set(re.findall(r'\b\d+(?:[.,:/-]\d+)*\b|\b[A-Z][a-z]+\b|\b(?:agreed|decided|approved|proposed|blocked|open|pending|moved|delayed|cancelled|shipped)\b', text)))


def percentile(values, p):
    return sorted(values)[min(len(values) - 1, int((len(values) - 1) * p))] if values else None


def packets(cases, rows, root):
    """Keep the judge kit's folder/files/slot envelope; use temporal faithfulness slots."""
    root = Path(root)
    sealed = {'protocol': 'judge-faithfulness-v1', 'packets': {}}
    for case in cases:
        distinct = []
        seen = set()
        for row in rows:
            key = (row['note_id'], row['revision'])
            if row['case_id'] == case['id'] and row['text'] and key not in seen:
                distinct.append(row); seen.add(key)
        payload = {'case_id': case['id'], 'rows': distinct, 'speech': case['speech'], 'vault': case.get('vault', [])}
        digest = sha(payload)
        lines = [f"# Case {case['id']}", 'Follow JUDGE.md. Judge assertions only against each row’s available sources.']
        slots = {}
        for row in distinct:
            key = f"{row['note_id']}.revision-{row['revision']}"
            lines += [f"## {key} · visible at {row['at']:.3f} s", f"Jot: {row['jot']}", f"Output: {row['text']}", '### Available transcript']
            available = set(row['available_segment_ids'])
            lines += [f"{s['id']} [{s['start']:.3f}–{s['end']:.3f}] {s['speaker']}: {s['text']}"
                      for s in case['speech'] if s['id'] in available]
            lines += ['### Source-note evidence (no meeting exists)' if not case['speech'] else '### Supplied background (names/definitions only, not meeting facts)']
            lines += [f"{v['id']} {v['title']}: {v['markdown']}" for v in case.get('vault', []) if v['id'] in row['background']]
            slots[key] = dict(kind='faithfulness', allowed=['supported', 'unsupported', 'contradicted'], verdict=None, quote=None)
        folder = root / case['id']
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'packet.md').write_text('\n\n'.join(lines) + '\n')
        todo = dict(case_id=case['id'], packet_id=digest[:10], packet_sha256=digest,
                    protocol='judge-faithfulness-v1', judge=None, slots=slots)
        # Re-emission never overwrites a judge's completed artifact.
        write(folder / 'judgment.todo.json', todo)
        sealed['packets'][case['id']] = dict(packet_id=digest[:10], packet_sha256=digest, rows=len(distinct))
    write(root / '_sealed' / 'run.json', sealed)
    (root / 'JUDGE.md').write_text('''# Faithfulness judge · judge-faithfulness-v1
Read only the chosen case folder. Copy judgment.todo.json to judgment.json, set judge,
and fill every slot. Preserve case_id, packet_id, packet_sha256 and the slot keys.
For each revision use ONLY the sources listed under that revision, and that jot.
When a case has no meeting transcript, source-note passages ARE evidence and may establish facts.
During meetings, background may explain names and terms but cannot establish meeting decisions or facts.
Choose supported, unsupported (a claim lacks evidence), or contradicted (available evidence
says otherwise). Do not score prose quality, completeness, or agreement with future speech.
Quote a short verbatim supporting/contradicting source as sID: "words"; for unsupported use
OUT: "unsupported words" | NONE. Never read _sealed or another case. Save judgment.json.
''')


def judgments(cases, rows, root):
    if root is None:
        return {}
    result = {}
    for c in cases:
        folder = Path(root) / c['id']
        path = folder / 'judgment.json'
        if not path.exists():
            continue
        todo = json.loads((folder / 'judgment.todo.json').read_text())
        distinct=[];seen=set()
        for row in rows:
            key=(row['note_id'],row['revision'])
            if row['case_id']==c['id'] and row['text'] and key not in seen:
                distinct.append(row);seen.add(key)
        expected=sha(dict(case_id=c['id'],rows=distinct,speech=c['speech'],vault=c.get('vault',[])))
        if todo['packet_sha256'] != expected:
            raise ValueError(f'{path}: packet does not match current replay')
        answer = json.loads(path.read_text())
        for key in ['case_id', 'packet_id', 'packet_sha256', 'protocol']:
            if answer.get(key) != todo[key]:
                raise ValueError(f'{path}: stale or mismatched {key}')
        if not answer.get('judge') or set(answer['slots']) != set(todo['slots']):
            raise ValueError(f'{path}: missing judge or changed slot set')
        for key, slot in answer['slots'].items():
            if slot.get('verdict') not in todo['slots'][key]['allowed'] or not slot.get('quote'):
                raise ValueError(f'{path}: invalid/pending slot {key}')
            note_id, rev = key.rsplit('.revision-', 1)
            row = next(r for r in rows if r['case_id'] == c['id'] and r['note_id'] == note_id and r['revision'] == int(rev))
            sources = {s['id']: s['text'] for s in c['speech'] if s['id'] in row['available_segment_ids']}
            sources.update({v['id']:v['markdown'] for v in c.get('vault', []) if v['id'] in row['background']})
            sources['OUT'] = row['text']; sources['NOTE'] = row['jot']
            parts=re.findall(r'([\w-]+):\s*"([^"]+)"',slot['quote'])
            if not parts or (slot['verdict']!='unsupported' and not any(source not in ['OUT','NOTE'] for source,_ in parts)):
                raise ValueError(f'{path}: source quote required in {key}')
            for source, quote in parts:
                if source not in sources or quote.casefold() not in sources[source].casefold():
                    raise ValueError(f'{path}: nonverbatim or unavailable quote in {key}')
            result[(c['id'], note_id, int(rev))] = slot['verdict']
    return result


def report(cases, run, judge_root=None):
    run = Path(run)
    rows = read(run / 'timeline.jsonl')
    passes = read(run / 'calls.jsonl')
    funnels = read(run / 'funnel.jsonl')
    verdicts = judgments(cases, rows, judge_root)
    jots = []
    updates = []
    for case in cases:
        for jot in case['jots']:
            history = [r for r in rows if r['case_id'] == case['id'] and r['note_id'] == jot['id']]
            if not history:
                raise ValueError(f"No timeline for {case['id']}/{jot['id']}")
            distinct = list({r['revision']: r for r in reversed(history) if r['text']}.values())[::-1]
            end = history[-1]; gold = case['gold'][jot['id']]
            revisions = [r['text'] for r in distinct]
            for row in distinct:
                if row['cause'].startswith('speech:'):
                    sid=row['cause'].split(':',1)[1]
                    source=next((x for x in case['speech'] if x['id']==sid),None)
                    if source: updates.append(row['at']-source.get('final_at',source['end']+.5))
            judged = [verdicts.get((case['id'], jot['id'], r['revision'])) for r in distinct]
            failures = any(v in ['unsupported', 'contradicted'] for v in judged)
            final_spec = gold['final']
            final_known = not final_spec.get('review_required', False)
            converged = bool(end['text']) and anchors(end['text'], final_spec) if final_known else None
            first = next((r for r in history if r['text']), None)
            def recall(row):
                available_gold = set(gold['evidence']) & set(row['available_segment_ids'])
                return len(available_gold & set(row['evidence'])) / len(available_gold) if available_gold else None
            milestones = []
            for m in gold['milestones']:
                at = m.get('at', next((s.get('final_at', s['end']+.5) for s in case['speech'] if s['id'] == m.get('after')), case['stop_at']))
                visible = [r for r in history if r['at'] <= at]
                text = visible[-1]['text'] if visible else ''
                milestones.append(dict(at=at, empty=not text, passed=not text or anchors(text, m), review_required=m.get('review_required', False)))
            selected_funnel = [f for f in funnels if f['case_id'] == case['id'] and f['note_id'] == jot['id']]
            funnel_scores=[]
            for f in selected_funnel:
                available=set(f.get('available_segment_ids', [s['id'] for s in case['speech'] if s.get('final_at',s['end']+.5)<=f['at']]))
                relevant=set(gold['evidence']) & available
                funnel_scores.append(dict(at=f['at'], heard_gold=sorted(relevant), **{
                    stage: len(relevant & set(f[stage]))/len(relevant) if relevant else None
                    for stage in ['candidates','kept','prompt']}))
            jots.append(dict(case_id=case['id'], note_id=jot['id'], abstain=gold['abstain'],
                quiet=not revisions, revisions=len(revisions), cosmetic=sum(facts(a)==facts(b) for a,b in zip(revisions,revisions[1:])),
                flaps=len(revisions)-len(set(revisions)), typed_to_first_seconds=first['at']-jot['at'] if first else None,
                found_seconds=next((f['at']-jot['at'] for f in selected_funnel if f.get('answerable', bool(f['prompt']))), None),
                recall_first=recall(first) if first else None, recall_settle=recall(end), converged=converged,
                background_recall=len(set(gold.get('background_note_ids',[])) & set(end['background']))/len(gold['background_note_ids']) if gold.get('background_note_ids') else None,
                faithful=None if any(v is None for v in judged) else not failures, unfaithful=failures,
                pending_judgments=sum(v is None for v in judged), milestones=milestones))
    calls = [c for p in passes for c in p['calls']]
    case_scores = []
    for c in cases:
        group = [j for j in jots if j['case_id']==c['id']]
        if all(j['converged'] is not None or j['abstain'] for j in group) and all(j['faithful'] is not None for j in group):
            case_scores.append(sum(j['converged'] is True and j['faithful'] for j in group if not j['abstain']) - 2*sum(j['unfaithful'] for j in group) + sum(j['quiet'] for j in group if j['abstain']))
    headline = None
    if len(case_scores)==len(cases):
        rng=random.Random(1729)
        samples=sorted(sum(rng.choices(case_scores,k=len(case_scores)))/len(case_scores) for _ in range(2000))
        headline=dict(mean=sum(case_scores)/len(case_scores), bootstrap_95=[samples[50],samples[1949]])
    totals = dict(cases=len(cases), jots=len(jots), answered=sum(j['revisions']>0 for j in jots),
        abstain=sum(j['abstain'] for j in jots), quiet_abstain=sum(j['abstain'] and j['quiet'] for j in jots),
        revisions=sum(j['revisions'] for j in jots), cosmetic=sum(j['cosmetic'] for j in jots), flaps=sum(j['flaps'] for j in jots),
        calls=len(calls), embedding_calls=sum(p['embedding_calls'] for p in passes), embedding_cache_hits=sum(p.get('embedding_cache_hits',0) for p in passes),
        generation_busy_seconds=sum(c['seconds'] for c in calls), pending_judgments=sum(j['pending_judgments'] for j in jots),
        prompt_tokens_p50=percentile([c['stats']['promptTokens'] for c in calls],.5),
        prompt_tokens_p95=percentile([c['stats']['promptTokens'] for c in calls],.95),
        ttft_ms_p50=percentile([c['stats']['ttftMs'] for c in calls],.5), ttft_ms_p95=percentile([c['stats']['ttftMs'] for c in calls],.95),
        typed_to_first_p50=percentile([j['typed_to_first_seconds'] for j in jots if j['typed_to_first_seconds'] is not None],.5),
        typed_to_first_p95=percentile([j['typed_to_first_seconds'] for j in jots if j['typed_to_first_seconds'] is not None],.95),
        headline=headline,
        stop_to_settle_p95=percentile([max((r['at'] for r in rows if r['case_id']==c['id']),default=c['stop_at'])-c['stop_at'] for c in cases],.95),
        speech_to_update_p50=percentile(updates,.5), speech_to_update_p95=percentile(updates,.95),
        revisions_p50=percentile([j['revisions'] for j in jots if j['revisions']],.5),
        revisions_p95=percentile([j['revisions'] for j in jots if j['revisions']],.95),
        generated_tokens_p50=percentile([c['stats']['generatedTokens'] for c in calls],.5),
        generated_tokens_p95=percentile([c['stats']['generatedTokens'] for c in calls],.95),
        cold_load_ms=max((c['stats']['loadMs'] for c in calls),default=0))
    totals['line_check_rejections'] = {reason:sum(call.get('rejection') == reason for call in calls) for reason in ['topicMixing','modality','numericConflict','attribution','superseded','absence','joke','unsupported','factsLost','cosmetic','flap','format','tooShort','abstained','modelError']}
    contamination=[]
    gold_by_case={c['id']:c['gold'] for c in cases}
    for f in funnels:
        golds=gold_by_case[f['case_id']]
        own=set(golds[f['note_id']]['evidence'])
        other=set().union(*(set(g['evidence']) for n,g in golds.items() if n != f['note_id']))-own
        contamination.extend(len(set(a)&other) for a in f.get('attempts',[]))
    totals['topic_excluded_candidate_pairs'] = sum(len(set(f['candidates']) - set(f['kept'])) for f in funnels)
    totals['found_jots']=sum(j['found_seconds'] is not None for j in jots)
    totals['other_jot_gold_per_call']=dict(calls=len(contamination), total=sum(contamination),
        mean=sum(contamination)/len(contamination) if contamination else 0,
        p50=percentile(contamination,.5), p95=percentile(contamination,.95))
    budgets = {
        'jot_to_state': dict(p50=percentile([j['found_seconds'] for j in jots if j['found_seconds'] is not None],.5),p95=percentile([j['found_seconds'] for j in jots if j['found_seconds'] is not None],.95),note='adapter selection frontier; current engine has no found state'),
        'jot_to_line': dict(p50=totals['typed_to_first_p50'],p95=totals['typed_to_first_p95']),
        'jot_to_line_one_ahead': dict(measured=None,reason='current engine batches by meeting; no per-query queue lane'),
        'speech_to_update': dict(p50=totals['speech_to_update_p50'],p95=totals['speech_to_update_p95'],note='includes current debounce/throttle'),
        'stop_to_settle': dict(p95=totals['stop_to_settle_p95']),
        'cold_load': dict(native_load_ms=totals['cold_load_ms'], process_start_to_line=None, note='native receipt excludes CLI asset hashing/setup and OS cache state'),
        'revisions': dict(p50=totals['revisions_p50'],p95=totals['revisions_p95']),
        'cosmetic_and_flaps': dict(cosmetic=totals['cosmetic'],flaps=totals['flaps'],note='diagnostic fact-anchor equality'),
        'calls': [dict(case_id=c['id'],duration=c['stop_at'],calls=sum(len(p['calls']) for p in passes if p['case_id']==c['id'])) for c in cases],
        'gpu_duty': dict(generation_wall_seconds=sum(c['stats']['totalMs']/1000 for c in calls),actual_gpu_utilization=None),
        'energy': dict(watts=None,reason='powermetrics not captured in virtual mode'),
        'thermal': dict(measured=None,reason='see audio.json for real-mode samples'),
        'asr_lag': dict(measured=None,reason='see audio.json; virtual mode does not recognize audio'),
        'memory': dict(measured=None,reason='see audio.json; 60-minute growth and post-Done return not measured'),
        'kv_prefixes': dict(measured=None,reason='current TextStats does not expose snapshot count/bytes'),
        'index_growth_meeting': dict(measured=None,reason='see audio.json; virtual replay uses existing planner snapshots'),
        'index_bytes_vault': dict(measured=None,reason='stage-2 shared index not implemented'),
        'purge': dict(measured=None,reason='existing retention regression suite; stage-2 canary not implemented'),
        'find_decide': dict(measured=None,reason='current selection combines embedding, retrieval and gates')}
    memory_path = run/'memory.json'
    if memory_path.exists():
        samples = json.loads(memory_path.read_text())
        budgets['memory'] = dict(samples=len(samples), peak_sampled_footprint_bytes=max((s['footprint_bytes'] for s in samples), default=0),
            note='Phase samples from this process; launcher peak is separate. Not a 60-minute growth measurement.')
    index_path = run/'index.jsonl'
    if index_path.exists():
        index_rows = read(index_path)
        budgets['index_growth_meeting'] = dict(cases=index_rows, note='actual shared SQLite and accelerator files; includes fixed schema overhead and any vault rows')
        budgets['index_bytes_vault'] = dict(cases=[r for r in index_rows if r['vault_chunks']], note='shared-store bytes; isolated per-chunk sizing is measured by EngineIndexTests')
        budgets['purge'] = dict(cases=[dict(case_id=r['case_id'], chunks=r['meeting_chunks_after_purge'], vectors=r['meeting_vectors_after_purge']) for r in index_rows], note='actual Index.purge after replay; byte-level canary is covered by EngineIndexTests')
    summary=dict(protocol='replay-v1' , totals=totals, jots=jots, budgets=budgets,
        unavailable={'faithfulness':'orchestrator judgments required', 'convergence':None if all(not c['gold'][n['id']]['final'].get('review_required',False) for c in cases for n in c['jots']) else 'some prose anchors require review',
        'energy':'launcher powermetrics required', 'find_decide':'current engine combines selection and embedding',
        'purge':'covered by product tests, not inferred from virtual replay'},
        notes=['cosmetic uses diagnostic fact anchors; it is not a quality judgment',
               'Current debounce/throttle and final pass; chunk/index stage recorded in index.jsonl when present'])
    write(run/'report.json',summary)
    lines=['# Replay baseline', '', '| Metric | Measured |', '|---|---:|']
    lines += [f'| {key} | {value if value is not None else "pending"} |' for key,value in totals.items()]
    lines += ['', '## Per jot', '', '| Case / jot | Revisions | First line, s | Recall at settle | Quiet |', '|---|---:|---:|---:|---|']
    lines += [f"| {j['case_id']} / {j['note_id']} | {j['revisions']} | {j['typed_to_first_seconds']} | {j['recall_settle']} | {j['quiet']} |" for j in jots]
    (run/'report.md').write_text('\n'.join(lines)+'\n')
    return summary


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    c=sub.add_parser('convert');c.add_argument('inputs',nargs='+');c.add_argument('--out',required=True);c.add_argument('--milestones',default=str(Path(__file__).parents[1]/'fixtures/replay-milestones.json'))
    r=sub.add_parser('report');r.add_argument('cases');r.add_argument('run');r.add_argument('--judgments');r.add_argument('--packets',action='store_true');r.add_argument('--case')
    a=p.parse_args()
    if a.command=='convert':
        cs=convert(a.inputs,a.out,a.milestones);print(f'{len(cs)} cases converted')
    else:
        cs=read(a.cases)
        if a.case: cs=[c for c in cs if c['id']==a.case]
        if a.packets:packets(cs,read(Path(a.run)/'timeline.jsonl'),Path(a.run)/'packets')
        print(json.dumps(report(cs,a.run,a.judgments)['totals'],indent=2))

if __name__=='__main__':
    main()
