import os
from pathlib import Path
import sys, time, numpy as np, torch, coremltools as ct
S=sys.argv[1]
m = ct.models.CompiledMLModel(str(Path(os.environ.get("WORKSCRIBE_RUNTIME_HOME", Path.home() / "Library/Application Support/WorkScribe/Runtime")) / "models/wespeaker_v2.mlmodelc"), compute_units=ct.ComputeUnit.ALL)
w = np.zeros((3,160000),np.float32); w[0]=np.random.randn(160000).astype(np.float32)*0.05
mk = np.zeros((3,589),np.float32); mk[0]=1
t=time.time(); o=m.predict({"waveform":w,"mask":mk}); print("wespeaker", {k:np.asarray(v).shape for k,v in o.items()}, time.time()-t)
from sentence_transformers import SentenceTransformer
import sentence_transformers, transformers; print(sentence_transformers.__version__, transformers.__version__)
dev = "mps" if torch.backends.mps.is_available() else "cpu"
model = SentenceTransformer(S+"/models/eg2", device=dev, config_kwargs={"vision_config": None}, model_kwargs={"torch_dtype": torch.float32})
print(model)
a = np.random.randn(16000*5).astype(np.float32)*0.05
for inp in [{"array":a,"sampling_rate":16000}, {"audio":{"array":a,"sampling_rate":16000}}]:
    try:
        t=time.time(); e=model.encode([inp]); print("ok", type(inp), e.shape, time.time()-t); break
    except Exception as ex: print("fail", repr(ex)[:300])
