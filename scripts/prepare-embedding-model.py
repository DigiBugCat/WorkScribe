#!/usr/bin/env python3
"""Download the pinned EmbeddingGemma 2 Core ML files for bundling; never called at runtime.

    scripts/prepare-embedding-model.py            # text model, token table, tokenizer (~585 MB)
    scripts/prepare-embedding-model.py --audio    # also the audio encoder (~588 MB)
    scripts/prepare-embedding-model.py --vision   # also the image encoder (~292 MB)

Files land in WORKSCRIBE_RUNTIME_HOME/models/embeddinggemma-2-coreml, are checked against the SHA-256 sums in
Resources/licenses/embeddinggemma2/MODEL-SHA256.json, and each .mlpackage is compiled once to .mlmodelc with
coremlcompiler so the app never compiles at launch. Models stay outside the app bundle in the runtime home.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen
from runtime_home import HOME, state, verified_tree

ROOT = Path(__file__).resolve().parents[1]
METADATA = json.loads((ROOT / "Resources/licenses/embeddinggemma2/MODEL-SHA256.json").read_text())
MIN_FREE = 6 * 1024**3


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(revision: str, path: str, expected: str, target: Path) -> None:
    if state(target) == "present" and sha256(target) == expected:
        return
    from runtime_doctor_download import download
    url = f"https://huggingface.co/{METADATA['repository']}/resolve/{revision}/{quote(path)}"
    download(url, expected, target)
    print(f"  {path}")


def prepare(part: str, folder: Path) -> None:
    spec = METADATA[part]
    revision, package = spec["revision"], spec["package"]
    stamp = folder / f"{package}.mlmodelc" / "workscribe-revision"
    if verified_tree(stamp.parent) and stamp.exists() and stamp.read_text().strip() == revision:
        print(f"{package} {revision[:8]} already prepared")
        return
    print(f"{package} @ {revision[:8]}")
    for path, expected in spec["files"].items():
        fetch(revision, path, expected, folder / path)
    compiled = folder / f"{package}.mlmodelc"
    backup = folder / f".{package}.previous"
    with tempfile.TemporaryDirectory(dir=folder, prefix=".compile-") as temporary:
        stage = Path(temporary)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(folder / f"{package}.mlpackage"), str(stage)],
                       check=True, stdout=subprocess.DEVNULL)
        prepared = stage / f"{package}.mlmodelc"
        (prepared / "workscribe-revision").write_text(revision + "\n")
        # Keep the old graph usable until the replacement has compiled successfully.
        shutil.rmtree(backup, ignore_errors=True)
        if compiled.exists(): compiled.rename(backup)
        try:
            prepared.rename(compiled)
        except Exception:
            if backup.exists(): backup.rename(compiled)
            raise
        shutil.rmtree(backup, ignore_errors=True)
    # The compiled model is what ships; the package is only its source.
    shutil.rmtree(folder / f"{package}.mlpackage")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vision", action="store_true", help="also prepare the image encoder (~292 MB)")
    parser.add_argument("--audio", action="store_true", help="also prepare the audio encoder (~588 MB)")
    parser.add_argument("--output", type=Path, default=HOME / "models/embeddinggemma-2-coreml")
    args = parser.parse_args()
    probe = args.output
    while not probe.exists():
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    if free < MIN_FREE:
        sys.exit(f"Only {free / 1024**3:.1f} GB free; need 6 GB to download and compile EmbeddingGemma 2. Skipped.")
    args.output.mkdir(parents=True, exist_ok=True)
    prepare("text", args.output)
    if args.vision:
        prepare("vision", args.output)
    if args.audio:
        prepare("audio", args.output)
    print(f"EmbeddingGemma 2 verified in {args.output}")


if __name__ == "__main__":
    main()
