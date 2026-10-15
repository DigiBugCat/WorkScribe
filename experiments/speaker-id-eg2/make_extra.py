"""All remaining >=3 s utterances (not in the eval manifest) -> training-only pool."""
import sys, glob, json, os, soundfile as sf
S = sys.argv[1]; root = f"{S}/data/LibriSpeech/test-clean"
used = {c["path"] for c in json.load(open(f"{S}/data/libri_manifest.json"))}
out = []
for f in sorted(glob.glob(f"{root}/*/*/*.flac")):
    if f in used: continue
    d = sf.info(f).duration
    if d < 3: continue
    dur = min(d, 10.0); key = os.path.basename(f)[:-5]
    out.append({"path": f, "spk": key.split("-")[0], "chapter": key.split("-")[1], "start": (d-dur)/2, "dur": dur})
json.dump(out, open(f"{S}/data/extra_manifest.json", "w")); print(len(out))
