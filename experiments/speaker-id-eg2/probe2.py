import sys, numpy as np, torch
from sentence_transformers import SentenceTransformer
S=sys.argv[1]
model = SentenceTransformer(S+"/models/eg2", device="cpu", config_kwargs={"vision_config": None}, model_kwargs={"torch_dtype": torch.float32})
hf = model[0].model
for n,c in hf.named_children(): print("child", n, type(c).__name__)
for n,m in hf.named_modules():
    if n.count(".")<=2: print(n, type(m).__name__)
a = np.random.randn(16000*5).astype(np.float32)*0.05
f = model.preprocess([{"array":a,"sampling_rate":16000}])
print({k:(v.shape if hasattr(v,'shape') else v) for k,v in f.items()})
