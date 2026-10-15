"""Pick 20 clips/speaker (3-10 s; longer utts center-cropped to 10 s like WorkScribe) from LibriSpeech test-clean, seed 0."""
import sys, glob, json, random, os, soundfile as sf
S = sys.argv[1]; random.seed(0); root = f"{S}/data/LibriSpeech/test-clean"
txt = {}
for t in glob.glob(f"{root}/*/*/*.trans.txt"):
    for line in open(t): k, v = line.strip().split(" ", 1); txt[k] = v
out = []
for spk in sorted(os.listdir(root)):
    fs = sorted(glob.glob(f"{root}/{spk}/*/*.flac")); random.shuffle(fs); n = 0
    for f in fs:
        d = sf.info(f).duration
        if d < 3: continue
        dur = min(d, 10.0); key = os.path.basename(f)[:-5]
        out.append({"path": f, "spk": spk, "chapter": key.split("-")[1], "start": (d-dur)/2, "dur": dur, "text": txt[key]}); n += 1
        if n == 20: break
json.dump(out, open(f"{S}/data/libri_manifest.json", "w"))
import collections; print(len(out), collections.Counter(c["spk"] for c in out).most_common()[-1], sum(c["dur"]<10 for c in out))
