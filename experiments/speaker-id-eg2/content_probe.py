"""Does EG2's final audio vector encode WHAT was said? Audio->transcript retrieval over the 800 LibriSpeech eval clips."""
import sys, json, numpy as np, torch
from sentence_transformers import SentenceTransformer
S = sys.argv[1]; ev = json.load(open(f"{S}/data/libri_manifest.json"))
A = np.load(f"{S}/emb/libri_eg.npy"); y = np.array([c["spk"] for c in ev])
m = SentenceTransformer(S+"/models/eg2", device="mps", config_kwargs={"vision_config": None, "audio_config": None}, model_kwargs={"torch_dtype": torch.float32})
T = m.encode([c["text"].lower() for c in ev], normalize_embeddings=True)
C = A @ T.T; full = np.array([c["dur"] < 10 for c in ev])  # uncropped clips: transcript matches audio exactly
r1 = (C.argmax(1) == np.arange(len(ev)))
print(f"audio->own transcript top-1 among 800: all {r1.mean():.3f}, uncropped {r1[full].mean():.3f}, cropped-to-10s {r1[~full].mean():.3f} (chance 0.00125)")
AA = A @ A.T; np.fill_diagonal(AA, -9); nn = AA.argmax(1); print(f"audio NN same speaker: {np.mean(y[nn]==y):.3f} (chance {19/799:.3f})")
