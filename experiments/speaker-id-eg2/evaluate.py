"""Speaker verification / identification eval: WeSpeaker v2 vs EmbeddingGemma 2 (+ adaptations).
2-fold over speakers: 20 train / 20 test speakers, swapped; metrics averaged. No speaker overlap."""
import sys, json, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from sklearn.decomposition import PCA
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_curve
S = sys.argv[1]; E = f"{S}/emb"
ev = json.load(open(f"{S}/data/libri_manifest.json")); ex = json.load(open(f"{S}/data/extra_manifest.json"))
y_ev = np.array([c["spk"] for c in ev]); y_ex = np.array([c["spk"] for c in ex]); dur = np.array([c["dur"] for c in ev])
def L(name): return np.load(f"{E}/libri_{name}.npy"), np.load(f"{E}/extra_{name}.npy")
feats = {"ws": L("ws"), "eg": L("eg")}
spks = np.array(sorted(set(y_ev))); rng0 = np.random.RandomState(0); perm = rng0.permutation(spks)
folds = [(set(perm[:20]), set(perm[20:])), (set(perm[20:]), set(perm[:20]))]
def l2(x): return x / np.linalg.norm(x, axis=1, keepdims=True).clip(1e-9)

# ---------- transforms: fit(train X, y) -> f(X)
def t_raw(dim=None):
    def fit(X, y):
        return lambda Z: l2(Z[:, :dim]) if dim else Z
    return fit
def t_center(X, y):
    m = X.mean(0); return lambda Z: Z - m
def t_whiten(X, y):
    p = PCA(n_components=min(200, X.shape[1]), whiten=True).fit(X); return lambda Z: p.transform(Z)
def t_lda(X, y):
    p = PCA(n_components=min(200, X.shape[1]), whiten=True).fit(X)
    l = LinearDiscriminantAnalysis(solver="eigen", shrinkage="auto").fit(p.transform(X), y)
    return lambda Z: l.transform(p.transform(Z))
def t_aam(hidden=0, out=128, epochs=400, s=30.0, m=0.2, seed=0):
    def fit(X, y):
        torch.manual_seed(seed); mu, sd = X.mean(0), X.std(0) + 1e-6
        Xt = torch.tensor((X - mu) / sd, dtype=torch.float32); cls = {c: i for i, c in enumerate(sorted(set(y)))}
        yt = torch.tensor([cls[c] for c in y])
        net = nn.Sequential(nn.Dropout(0.2), nn.Linear(X.shape[1], out)) if not hidden else \
              nn.Sequential(nn.Dropout(0.2), nn.Linear(X.shape[1], hidden), nn.BatchNorm1d(hidden), nn.ReLU(), nn.Linear(hidden, out))
        W = nn.Parameter(torch.randn(len(cls), out) * 0.01)
        opt = torch.optim.Adam(list(net.parameters()) + [W], lr=1e-3, weight_decay=1e-3)
        for _ in range(epochs):
            net.train(); e = F.normalize(net(Xt)); cos = e @ F.normalize(W).T
            th = torch.acos(cos.clamp(-1+1e-6, 1-1e-6)); oh = F.one_hot(yt, len(cls)).bool()
            logits = s * torch.where(oh, torch.cos(th + m), cos)
            loss = F.cross_entropy(logits, yt); opt.zero_grad(); loss.backward(); opt.step()
        net.eval()
        return lambda Z: net(torch.tensor((Z - mu) / sd, dtype=torch.float32)).detach().numpy()
    return fit
def chain(*fs):
    def fit(X, y):
        g = []
        for f in fs: t = f(X, y); g.append(t); X = t(X)
        def ap(Z):
            for t in g: Z = t(Z)
            return Z
        return ap
    return fit

# ---------- metrics on a test score matrix
def eer_tpr(C, y, mask=None):
    iu = np.triu_indices(len(y), 1); same = (y[:, None] == y[None])[iu]; sc = C[iu]
    if mask is not None: keep = mask[iu]; same, sc = same[keep], sc[keep]
    fpr, tpr, th = roc_curve(same, sc); fnr = 1 - tpr; i = np.nanargmin(np.abs(fnr - fpr))
    return (fpr[i] + fnr[i]) / 2, np.interp(0.01, fpr, tpr), th[i]
def ident(C, y, reps=10, rule=(0.65, 0.12)):
    """WorkScribe-style: 3 enrollment clips/speaker, profile score = max cosine over its clips.
    Closed set: top-1 acc. Open set: half of speakers enrolled; rule = best>=0.65 and lead>=0.12."""
    r = np.random.RandomState(1); us = np.array(sorted(set(y))); acc = []; ok = []; wrong = []; fa = []
    for _ in range(reps):
        enr = {u: r.choice(np.where(y == u)[0], 3, replace=False) for u in us}
        q = np.array([i for i in range(len(y)) if i not in set(np.concatenate(list(enr.values())))])
        P = np.stack([C[q][:, enr[u]].max(1) for u in us], 1)  # [nq, nspk]
        acc.append(np.mean(us[P.argmax(1)] == y[q]))
        sub = r.permutation(us)[:len(us)//2]; si = np.isin(us, sub); Ps = P[:, si]; top = np.sort(Ps, 1)
        accept = (top[:, -1] >= rule[0]) & (top[:, -1] - top[:, -2] >= rule[1]); pred = us[si][Ps.argmax(1)]
        gen = np.isin(y[q], sub)
        ok.append(np.mean(accept[gen] & (pred[gen] == y[q][gen]))); wrong.append(np.mean(accept[gen] & (pred[gen] != y[q][gen])))
        fa.append(np.mean(accept[~gen]))
    return np.mean(acc), np.mean(ok), np.mean(wrong), np.mean(fa)
def logreg_ident(Z, y, reps=10):
    r = np.random.RandomState(1); us = np.array(sorted(set(y))); acc = []
    for _ in range(reps):
        e = np.concatenate([r.choice(np.where(y == u)[0], 3, replace=False) for u in us]); q = np.setdiff1d(np.arange(len(y)), e)
        clf = LogisticRegression(C=1.0, max_iter=2000).fit(l2(Z[e]), y[e]); acc.append(np.mean(clf.predict(l2(Z[q])) == y[q]))
    return np.mean(acc)

def run(feat, fit, tag):
    Xe, Xx = feats[feat]; R = []; Cs = []
    for tr, te in folds:
        Xtr = np.concatenate([Xe[np.isin(y_ev, list(tr))], Xx[np.isin(y_ex, list(tr))]])
        ytr = np.concatenate([y_ev[np.isin(y_ev, list(tr))], y_ex[np.isin(y_ex, list(tr))]])
        f = fit(Xtr, ytr); ti = np.isin(y_ev, list(te)); Z = l2(f(Xe[ti])); C = Z @ Z.T
        R.append(eer_tpr(C, y_ev[ti])[:2] + ident(C, y_ev[ti])); Cs.append((C, ti, f, Xtr, ytr))
    r = np.mean(R, 0); res[tag] = dict(zip(["eer", "tpr1", "id_acc", "ws_ok", "ws_wrong", "ws_fa"], map(float, r)))
    print(f"{tag:34s} EER {100*r[0]:5.1f}%  TPR@1%FPR {100*r[1]:5.1f}%  ID {100*r[2]:5.1f}%  | rule: ok {100*r[3]:5.1f} wrong {100*r[4]:4.1f} impostorFA {100*r[5]:4.1f}", flush=True)
    return Cs
res = {}; keep = {}
print("== baselines (test halves, 2-fold avg) =="); keep["ws"] = run("ws", t_raw(), "WeSpeaker v2 raw")
run("ws", t_center, "WeSpeaker v2 centered"); keep["ws_lda"] = run("ws", t_lda, "WeSpeaker v2 PCA-whiten+LDA")
print("== EG2 final embedding ==")
keep["eg"] = run("eg", t_raw(), "EG2 768 raw")
for d in [512, 256, 128]: run("eg", t_raw(d), f"EG2 {d} raw (Matryoshka)")
run("eg", t_center, "EG2 768 centered"); run("eg", t_whiten, "EG2 768 PCA-whiten")
keep["eg_lda"] = run("eg", t_lda, "EG2 768 PCA-whiten+LDA")
run("eg", chain(t_raw(256), t_lda), "EG2 256 PCA-whiten+LDA")
run("eg", t_aam(), "EG2 768 linear AAM proj")
run("eg", t_aam(hidden=512), "EG2 768 MLP AAM proj")
print("== EG2 audio-encoder layer taps (frame mean+std pooled) ==")
TAPK = ["conv"] + list(range(12)) + ["proj"]
for k in TAPK:
    if f"tap{k}" not in feats: feats[f"tap{k}"] = L(f"tap{k}")
    run(f"tap{k}", t_center, f"tap{k} centered"); run(f"tap{k}", t_lda, f"tap{k} PCA-whiten+LDA")
best = min([k for k in res if k.startswith("tap") and "LDA" in k], key=lambda k: res[k]["eer"]); bk = best.split()[0][3:]
print("best tap:", best)
fd = feats[f"tap{bk}"]; D = fd[0].shape[1] // 2
feats["tapmean"] = (fd[0][:, :D], fd[1][:, :D]); run("tapmean", t_lda, f"tap{bk} mean-only PCA-whiten+LDA")
run(f"tap{bk}", t_aam(), f"tap{bk} linear AAM proj"); run(f"tap{bk}", t_aam(hidden=512), f"tap{bk} MLP AAM proj")
run(f"tap{bk}", t_aam(out=256, epochs=800), f"tap{bk} linear AAM proj 256d/800ep")
early = ["conv", 0, 1, 2, 3]
feats["early"] = tuple(np.concatenate([feats[f"tap{k}"][i] for k in early], 1) for i in (0, 1))
run("early", t_lda, "taps conv+0..3 concat PCA-whiten+LDA"); run("early", t_aam(), "taps conv+0..3 concat linear AAM")

# ---------- fusion: z-norm + weight tuned on an INNER speaker split of the train half (no test leakage, no train-overfit scores)
def trainset(feat, sp):
    Xe, Xx = feats[feat]; sp = list(sp)
    return np.concatenate([Xe[np.isin(y_ev, sp)], Xx[np.isin(y_ex, sp)]]), np.concatenate([y_ev[np.isin(y_ev, sp)], y_ex[np.isin(y_ex, sp)]])
def scores(feat, fit, tr, idx):
    f = fit(*trainset(feat, tr)); Z = l2(f(feats[feat][0][idx])); return Z @ Z.T
def fuse(a, b, tag):
    R = []
    for tr, te in folds:
        rr = np.random.RandomState(2).permutation(sorted(tr)); A, B = set(rr[:10]), set(rr[10:]); bi = np.isin(y_ev, list(B))
        Ta, Tb = scores(a[0], a[1], A, bi), scores(b[0], b[1], A, bi); iu = np.triu_indices(bi.sum(), 1)
        na, nb = (Ta[iu].mean(), Ta[iu].std()), (Tb[iu].mean(), Tb[iu].std()); z = lambda C, n: (C - n[0]) / n[1]
        w = min(np.linspace(0, 1, 21), key=lambda w: eer_tpr(w*z(Ta, na) + (1-w)*z(Tb, nb), y_ev[bi])[0])
        ti = np.isin(y_ev, list(te)); Ca, Cb = scores(a[0], a[1], tr, ti), scores(b[0], b[1], tr, ti)
        C = w*z(Ca, na) + (1-w)*z(Cb, nb)
        R.append(eer_tpr(C, y_ev[ti])[:2] + ident(C, y_ev[ti])[:1] + (w,))
    r = np.mean(R, 0); res[tag] = {"eer": float(r[0]), "tpr1": float(r[1]), "id_acc": float(r[2]), "w_ws": float(r[3])}
    print(f"{tag:34s} EER {100*r[0]:5.2f}%  TPR@1%FPR {100*r[1]:5.1f}%  ID {100*r[2]:5.1f}%  (WeSpeaker weight {r[3]:.2f})", flush=True)
print("== fusion (score-level) ==")
WS = ("ws", t_raw())
fuse(WS, ("eg", t_center), "fuse WS + EG2 768 centered"); fuse(WS, ("eg", t_lda), "fuse WS + EG2 768 LDA")
fuse(WS, (f"tap{bk}", t_lda), f"fuse WS + tap{bk} LDA"); fuse(WS, (f"tap{bk}", t_aam()), f"fuse WS + tap{bk} AAM")
fuse(WS, ("early", t_lda), "fuse WS + early-taps LDA")
print("WS raw EER at 2 decimals:", round(100*res["WeSpeaker v2 raw"]["eer"], 2))

print("== by clip duration (EER, both clips in bucket) ==")
for k, fit in [("ws", t_raw()), ("eg", t_raw()), (f"tap{bk}", t_aam())]:
    out = []
    for lo, hi in [(3, 6), (6, 9.99), (9.99, 11)]:
        e = []
        for tr, te in folds:
            ti = np.isin(y_ev, list(te)); C = scores(k, fit, tr, ti); dm = (dur[ti] >= lo) & (dur[ti] < hi)
            e.append(eer_tpr(C, y_ev[ti], dm[:, None] & dm[None])[0])
        out.append(f"{lo}-{hi}s {100*np.mean(e):.1f}%")
    print(k, out); res[f"dur_{k}"] = out
print("n clips per bucket:", [int(((dur >= lo) & (dur < hi)).sum()) for lo, hi in [(3, 6), (6, 9.99), (9.99, 11)]])
print("== Reflex-style logistic head on 3 enrollment clips/speaker (closed set, test speakers) ==")
for k in ["ws", "eg", f"tap{bk}", "early"]:
    a = []
    for tr, te in folds:
        Xe = feats[k][0]; ti = np.isin(y_ev, list(te)); m = Xe[~ti].mean(0); a.append(logreg_ident(Xe[ti] - m, y_ev[ti]))
    print(f"logreg {k}: {100*np.mean(a):.1f}%"); res[f"logreg_{k}"] = float(np.mean(a))
json.dump(res, open(f"{E}/results.json", "w"), indent=1)
