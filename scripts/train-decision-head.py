#!/usr/bin/env python3
"""Fit native decision heads from replay-exported features; no product or cloud inference.

Candidate selection and prompt budgeting happen in Swift. The exported rows carry
labels and case provenance, with no injected-gold candidate shortcut. Temperature
is fitted on inner case-held-out predictions, never on the outer held-out case.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import sys
import time
import warnings
import numpy as np
from scipy.optimize import minimize_scalar
from scipy.special import expit, logit
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.neural_network import MLPClassifier
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.exceptions import ConvergenceWarning

warnings.filterwarnings("ignore", category=ConvergenceWarning)
STOP = set(
    "a an the is are was were to for of and or in on at it this that we i you with be do does did".split()
)
FEATURES = [
    "cosine",
    "time_gap_600",
    "speaker_change",
    "query_coverage",
    "jaccard",
    "log_words",
]
ANSWER_FEATURES = [
    "max_cosine",
    "mean_top3_cosine",
    "max_coverage",
    "union_coverage",
    "max_jaccard",
    "nearest_gap_600",
    "log_candidates",
]


def estimator(name):
    return make_pipeline(
        StandardScaler(),
        (
            LogisticRegression(C=0.1, max_iter=400)
            if name.startswith("logistic")
            else MLPClassifier(
                hidden_layer_sizes=(16,),
                alpha=10,
                max_iter=250,
                random_state=17,
                early_stopping=False,
            )
        ),
    )


def fit_predict(name, X, y, train, test):
    if len(set(y[train])) < 2:
        return np.full(len(test), np.mean(y[train])), None
    m = estimator(name)
    m.fit(X[train], y[train])
    return m.predict_proba(X[test])[:, 1], m


def temperature(logits, y):
    def loss(logt):
        z = logits / np.exp(logt)
        return np.mean(np.logaddexp(0, z) - y * z)

    return float(np.exp(minimize_scalar(loss, bounds=(-2.3, 3), method="bounded").x))


def metrics(y, p):
    ece = 0
    for lo in np.arange(0, 1, 0.1):
        use = (p >= lo) & (p < lo + 0.1 if lo < 0.9 else p <= 1)
        if use.any():
            ece += use.mean() * abs(y[use].mean() - p[use].mean())
    pred = p >= 0.5
    pos = y == 1
    neg = ~pos
    return dict(
        n=len(y),
        positive=int(sum(pos)),
        negative=int(sum(neg)),
        accuracy=float(np.mean(pred == y)),
        auroc=float(roc_auc_score(y, p)) if pos.any() and neg.any() else None,
        ece=float(ece),
        brier=float(np.mean((p - y) ** 2)),
        recall=float(pred[pos].mean()) if pos.any() else None,
        specificity=float((~pred[neg]).mean()) if neg.any() else None,
    )


def evaluate(rows, name, external=None, recall_target=None):
    y = np.array([r["label"] for r in rows])
    groups = np.array([r["case_id"] for r in rows])
    cases = sorted(set(groups))
    feature = "vector" if name.endswith("vector") else "cheap"
    X = np.array([r[feature] for r in rows])
    out = np.zeros(len(y))
    raw = np.zeros(len(y))
    decisions = np.zeros(len(y))
    folds = []
    for case in cases:
        tr = np.where(groups != case)[0]
        te = np.where(groups == case)[0]
        inner = np.zeros(len(y))
        for held in cases:
            if held == case:
                continue
            itr = np.where((groups != case) & (groups != held))[0]
            ite = np.where(groups == held)[0]
            inner[ite] = (
                external[ite]
                if external is not None
                else fit_predict(name, X, y, itr, ite)[0]
            )
        t = temperature(logit(np.clip(inner[tr], 1e-7, 1 - 1e-7)), y[tr])
        p = external[te] if external is not None else fit_predict(name, X, y, tr, te)[0]
        raw[te] = p
        out[te] = expit(logit(np.clip(p, 1e-7, 1 - 1e-7)) / t)
        threshold = 0.5
        if recall_target is not None:
            calibration = expit(logit(np.clip(inner[tr], 1e-7, 1 - 1e-7)) / t)
            threshold = float(
                np.quantile(calibration[y[tr] == 1], 1 - recall_target, method="lower")
            )
        decisions[te] = out[te] >= threshold
        folds.append(
            dict(
                held_out=case,
                temperature=t,
                threshold=threshold,
                **metrics(y[te], out[te])
            )
        )
    full = None
    if external is None:
        full = estimator(name)
        full.fit(X, y)
    latency = []
    if full:
        for _ in range(50):
            start = time.perf_counter()
            full.predict_proba(X[:1])
            latency.append((time.perf_counter() - start) * 1000)
    operating = metrics(y, decisions)
    operating = {
        k: operating[k]
        for k in ["n", "positive", "negative", "accuracy", "recall", "specificity"]
    }
    result = dict(
        operating_point=operating,
        calibrated=metrics(y, out),
        uncalibrated=metrics(y, raw),
        folds=folds,
        head_latency_ms_p50=float(np.median(latency)) if latency else None,
        head_latency_ms_p95=float(np.percentile(latency, 95)) if latency else None,
        predictions=[
            dict(
                case_id=r["case_id"],
                note_id=r["note_id"],
                segment_id=r.get("segment_id"),
                label=r["label"],
                probability=float(p),
                raw_probability=float(a),
            )
            for r, p, a in zip(rows, out, raw)
        ],
    )
    export = None
    if full is not None:
        scale, head = full.steps[0][1], full.steps[1][1]
        export = dict(
            feature_kind=feature,
            mean=scale.mean_.tolist(),
            scale=scale.scale_.tolist(),
            temperature=temperature(logit(np.clip(raw, 1e-7, 1 - 1e-7)), y),
        )
        if recall_target is not None:
            deployment = expit(
                logit(np.clip(raw, 1e-7, 1 - 1e-7)) / export["temperature"]
            )
            export["threshold"] = float(
                np.quantile(deployment[y == 1], 1 - recall_target, method="lower")
            )
        if name.startswith("logistic"):
            export.update(
                weights=head.coef_[0].tolist(), bias=float(head.intercept_[0])
            )
        else:
            export.update(
                layers=[w.tolist() for w in head.coefs_],
                biases=[b.tolist() for b in head.intercepts_],
            )
        result["head_parameter_bytes"] = sum(
            a.nbytes
            for a in (
                [scale.mean_, scale.scale_, head.coef_, head.intercept_]
                if name.startswith("logistic")
                else [scale.mean_, scale.scale_, *head.coefs_, *head.intercepts_]
            )
        )
    return result, export



def main():
    p=argparse.ArgumentParser(description='Train decision heads on --replay --export-pairs; nested case-held-out calibration')
    p.add_argument('--pairs',required=True)
    p.add_argument('--embedding-model',required=True)
    p.add_argument('--out',required=True)
    a=p.parse_args()
    rows=[json.loads(x) for x in Path(a.pairs).read_text().splitlines() if x.strip()]
    out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
    report=dict(split='nested leave-one-case-out; inner out-of-fold temperature',tasks={})
    model=dict(version=1,embeddingModel=a.embedding_model,relevanceThreshold=.5,answerabilityThreshold=.5,heads={})
    for task in ['relevance','answerability']:
        selected=[r for r in rows if r['task']==task]
        if len({r['case_id'] for r in selected})<3 or len({r['label'] for r in selected})<2:
            raise ValueError('Need at least three cases and both labels for '+task)
        result, head=evaluate(selected,'logistic-cheap',recall_target=.987 if task=='relevance' else None)
        report['tasks'][task]=result;model['heads'][task]=head
        if task=='relevance':model['relevanceThreshold']=head['threshold']
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    (out/'model.json').write_text(json.dumps(model,indent=2)+'\n')

if __name__=='__main__': main()
