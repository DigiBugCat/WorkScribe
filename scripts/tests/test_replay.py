import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('replay',Path(__file__).parents[1]/'replay.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)

class ReplayTests(unittest.TestCase):
    def fixture(self):
        case=dict(id='c',status='reviewed',speech=[dict(id='s1',speaker='A',start=0,end=5,text='Budget Monday.'),dict(id='s2',speaker='A',start=20,end=22,text='SECRET_FUTURE Tuesday.')],jots=[dict(id='n1',text='budget?',at=6)],stop_at=30,gold={'n1':dict(abstain=False,evidence=['s1'],milestones=[dict(after='s1',must=['Monday'],must_not=[])],final=dict(must=['Monday'],must_not=[]))})
        row=dict(case_id='c',note_id='n1',revision=1,at=12,cause='jot',state='answered',text='Budget Monday.',jot='budget?',available_segment_ids=['s1'],evidence=['s1'],background=[])
        return case,row
    def test_packets_are_blind_and_cannot_see_future(self):
        case,row=self.fixture()
        with tempfile.TemporaryDirectory() as d:
            r.packets([case],[row],d)
            text=(Path(d)/'c/packet.md').read_text()
            self.assertNotIn('SECRET_FUTURE',text)
            self.assertNotIn('model_id',text)
            todo=json.loads((Path(d)/'c/judgment.todo.json').read_text());todo['judge']='fixture'
            todo['slots']['n1.revision-1'].update(verdict='supported',quote='s1: "Budget Monday."')
            r.write(Path(d)/'c/judgment.json',todo)
            self.assertEqual(r.judgments([case],[row],d)[('c','n1',1)],'supported')
            todo['slots']['n1.revision-1']['quote']='s2: "SECRET_FUTURE Tuesday."'
            r.write(Path(d)/'c/judgment.json',todo)
            with self.assertRaises(ValueError):r.judgments([case],[row],d)
    def test_vault_without_meeting_is_judgable_evidence(self):
        case,row=self.fixture(); case['speech']=[]
        case['vault']=[dict(id='v1',title='Source',markdown='Budget Monday.')]
        row['available_segment_ids']=[]; row['background']=['v1']
        with tempfile.TemporaryDirectory() as d:
            r.packets([case],[row],d)
            self.assertIn('Source-note evidence', (Path(d)/'c/packet.md').read_text())
            todo=json.loads((Path(d)/'c/judgment.todo.json').read_text()); todo['judge']='fixture'
            todo['slots']['n1.revision-1'].update(verdict='supported',quote='v1: "Budget Monday."')
            r.write(Path(d)/'c/judgment.json',todo)
            self.assertEqual(r.judgments([case],[row],d)[('c','n1',1)],'supported')

    def test_stale_judgments_are_rejected(self):
        case,row=self.fixture()
        with tempfile.TemporaryDirectory() as d:
            r.packets([case],[row],d)
            todo=json.loads((Path(d)/'c/judgment.todo.json').read_text());todo['packet_sha256']='wrong'
            r.write(Path(d)/'c/judgment.json',todo)
            with self.assertRaises(ValueError):r.judgments([case],[row],d)
    def test_empty_milestone_is_safe_but_empty_final_is_not_convergence(self):
        case,row=self.fixture();row['text']='';row['revision']=0
        with tempfile.TemporaryDirectory() as d:
            for name,values in [('timeline.jsonl',[row]),('calls.jsonl',[]),('funnel.jsonl',[])]:
                (Path(d)/name).write_text(''.join(json.dumps(v)+'\n' for v in values))
            report=r.report([case],d)
            self.assertFalse(report['jots'][0]['converged'])
            self.assertTrue(report['jots'][0]['milestones'][0]['passed'])

    def test_supplied_anchor_sets_cover_jots_and_accept_their_reference(self):
        root=Path(__file__).parents[2]
        anchors=json.loads((root/'fixtures/replay-anchors.json').read_text())
        cases=r.read(root/'fixtures/retrieval-vault.jsonl')
        import re
        for case in cases:
            self.assertEqual(set(anchors[case['id']]),{n['id'] for n in case['notes']})
            for gold in case['gold_lines']:
                patterns=anchors[case['id']][gold['note_id']]
                self.assertEqual(not patterns,gold['abstain'])
                reference=gold.get('ideal') or ' '.join(s['text'] for s in case['segments'])
                for pattern in patterns:
                    self.assertRegex(reference,re.compile(pattern,re.I),f"{case['id']}/{gold['note_id']}")

    def test_contamination_counts_other_gold_once_and_excludes_shared_gold(self):
        import copy
        case,row=self.fixture()
        case['jots'].append(dict(id='n2',text='other?',at=6))
        case['gold']['n2']=copy.deepcopy(case['gold']['n1'])
        case['gold']['n2']['evidence']=['s1','s2']
        other=dict(row,note_id='n2',text='',revision=0)
        funnel=dict(case_id='c',note_id='n1',at=12,candidates=['s1','s2'],kept=['s1','s2'],prompt=['s1','s2'],attempts=[['s1','s2','s2']],available_segment_ids=['s1'])
        with tempfile.TemporaryDirectory() as d:
            for name,values in [('timeline.jsonl',[row,other]),('calls.jsonl',[]),('funnel.jsonl',[funnel])]:
                (Path(d)/name).write_text(''.join(json.dumps(v)+'\n' for v in values))
            result=r.report([case],d)['totals']['other_jot_gold_per_call']
            self.assertEqual(result,dict(calls=1,total=1,mean=1,p50=1,p95=1))
