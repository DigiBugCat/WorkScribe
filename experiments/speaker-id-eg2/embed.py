"""Embed clips with WeSpeaker v2 (WorkScribe's exact Core ML model + feeding) and EmbeddingGemma 2 (audio).
usage: embed.py S manifest.json outprefix"""
import os
from pathlib import Path
import sys, json, time, numpy as np, soundfile as sf, torch, coremltools as ct
S, manifest, out = sys.argv[1], sys.argv[2], sys.argv[3]
clips = json.load(open(manifest))
def load(c):
    a, sr = sf.read(c["path"], dtype="float32"); assert sr == 16000
    if a.ndim > 1: a = a.mean(1)
    s, e = int(c["start"]*16000), int((c["start"]+c["dur"])*16000)
    return a[s:e]
# --- WeSpeaker v2, as FluidAudio EmbeddingExtractor + VoiceEngine call it
ws = ct.models.CompiledMLModel(str(Path(os.environ.get("WORKSCRIBE_RUNTIME_HOME", Path.home() / "Library/Application Support/WorkScribe/Runtime")) / "models/wespeaker_v2.mlmodelc"), compute_units=ct.ComputeUnit.ALL)
mask = np.zeros((3,589), np.float32); mask[0] = 1
def wespeaker(a):
    w = np.zeros((3,160000), np.float32); n = min(len(a),160000); w[0,:n] = a[:n]
    while n < 160000:  # repeat-pad like fillWaveformBuffer
        c = min(n, 160000-n); w[0,n:n+c] = w[0,:c]; n += c
    return np.asarray(ws.predict({"waveform": w, "mask": mask})["embedding"])[0]
WS, t = [], time.time()
for c in clips: WS.append(wespeaker(load(c)))
ws_t = (time.time()-t)/len(clips); np.save(out+"_ws.npy", np.stack(WS)); print("wespeaker s/clip", ws_t, flush=True)
# --- EmbeddingGemma 2, audio only
from sentence_transformers import SentenceTransformer
dev = sys.argv[4] if len(sys.argv) > 4 else ("mps" if torch.backends.mps.is_available() else "cpu")
model = SentenceTransformer(S+"/models/eg2", device=dev, config_kwargs={"vision_config": None}, model_kwargs={"torch_dtype": torch.float32})
at = model[0].model.audio_tower
TAPS = list(range(12)); cap = {}
def hook(i):
    def f(m, inp, o): cap[i] = (o[0] if isinstance(o, tuple) else o).detach()
    return f
for i in TAPS: at.layers[i].register_forward_hook(hook(i))
at.output_proj.register_forward_hook(hook("proj")); at.subsample_conv_projection.register_forward_hook(hook("conv"))
EG, TAP = [], {k: [] for k in TAPS+["proj","conv"]}
model.encode([{"array": load(clips[0]), "sampling_rate": 16000}])  # warmup
t = time.time()
for j, c in enumerate(clips):
    e = model.encode([{"array": load(c), "sampling_rate": 16000}], convert_to_numpy=True)[0]
    EG.append(e)
    for k in TAP:
        h = cap[k][0].float()  # [T, D]
        TAP[k].append(torch.cat([h.mean(0), h.std(0)]).cpu().numpy())
    if j % 100 == 0: print(j, time.time()-t, flush=True)
eg_t = (time.time()-t)/len(clips)
np.save(out+"_eg.npy", np.stack(EG))
for k in TAP: np.save(out+f"_tap{k}.npy", np.stack(TAP[k]))
json.dump({"wespeaker_s_per_clip": ws_t, "eg2_s_per_clip": eg_t, "eg2_device": dev}, open(out+"_timing.json","w"))
print("eg2 s/clip", eg_t, dev)
