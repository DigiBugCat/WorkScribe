#!/usr/bin/env python3
"""Download the pinned FluidAudio voice model for bundling; never called at runtime."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "Resources/licenses/fluidaudio"
REVISION = (METADATA / "MODEL-REVISION.txt").read_text().strip()
for path, expected in json.loads((METADATA / "MODEL-SHA256.json").read_text()).items():
    target = ROOT / ".runtime/models" / path
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
        continue
    url = f"https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/{REVISION}/{path}"
    with urlopen(url) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f"Checksum mismatch: {path}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(path)
print("FluidAudio voice model verified")
