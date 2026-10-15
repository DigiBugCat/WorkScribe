"""Content-vs-voice probe on macOS `say` TTS: 8 voices x 10 identical sentences."""
import sys, json, numpy as np
S = sys.argv[1]; m = json.load(open(f"{S}/data/say_manifest.json"))
spk = np.array([c["spk"] for c in m]); txt = np.array([c["text"] for c in m])
def n(x): x = x - 0; return x/np.linalg.norm(x,axis=1,keepdims=True)
reps = {"wespeaker": np.load(f"{S}/emb/say_ws.npy"), "eg2_final": np.load(f"{S}/emb/say_eg.npy")}
for k in [2,5,8,11,"proj"]: reps[f"eg2_tap{k}"] = np.load(f"{S}/emb/say_tap{k}.npy")
iu = np.triu_indices(len(m),1)
for name, X in reps.items():
    X = n(X); C = X@X.T; ss = (spk[:,None]==spk[None])[iu]; st = (txt[:,None]==txt[None])[iu]; c = C[iu]
    a, b, d = c[ss&~st].mean(), c[~ss&st].mean(), c[~ss&~st].mean()
    # nearest neighbour: does it land on same voice or same text?
    np.fill_diagonal(C,-9); nn = C.argmax(1)
    print(f"{name:12s} sameVoice/diffText={a:.3f} diffVoice/sameText={b:.3f} diffBoth={d:.3f}  NN same voice={np.mean(spk[nn]==spk):.2f} NN same text={np.mean(txt[nn]==txt):.2f}")
