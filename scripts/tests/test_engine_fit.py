import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('fit',Path(__file__).resolve().parents[1]/'fit-engine.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)


def row(case,hit):
    return dict(case_id=case,note_id='n',abstain=False,converged=hit,faithful=True,unfaithful=False,quiet=False)


class FittingTests(unittest.TestCase):
    def test_held_out_case_cannot_select_its_own_arm(self):
        arms={'a-only':dict(jots=[row(c,c=='a') for c in 'abc']),
              'bc-only':dict(jots=[row(c,c!='a') for c in 'abc'])}
        fold=next(x for x in f.fit(arms)['folds'] if x['held_out']=='a')
        self.assertEqual(fold['arm'],'bc-only')
        self.assertEqual(fold['score'],0)
        arms['a-only']['jots'][0]['converged']=False
        self.assertEqual(next(x for x in f.fit(arms)['folds'] if x['held_out']=='a')['arm'],fold['arm'])
    def test_missing_judgments_or_cases_cannot_be_promoted(self):
        with self.assertRaises(ValueError):f.fit({'a':dict(jots=[row('x',None),row('y',True)])})
        with self.assertRaises(ValueError):f.fit({'a':dict(jots=[row('x',True)]),'b':dict(jots=[row('y',True)])})
