#!/usr/bin/env python3
"""Repair local runtime assets. Downloads publish atomically after checksum validation."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tarfile
import tempfile
import uuid
import urllib.request
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
from runtime_home import HOME, CACHE, state, sha256

ROOT = Path(__file__).resolve().parents[1]
META = ROOT / 'Resources/licenses'

def log(message):
    print(message, flush=True)

from runtime_doctor_download import download

def materialize(path):
    if state(path) != 'evicted':
        return
    subprocess.run(['/usr/bin/brctl', 'download', str(path)], check=True, timeout=30, stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 120
    while state(path) == 'evicted':
        if time.monotonic() > deadline:
            raise RuntimeError(f'iCloud download timed out: {path}')
        time.sleep(1)

def migrate(source, destination=None):
    destination = destination or HOME
    if not source.exists() or source.resolve() == destination.resolve():
        return
    for path in source.rglob('*'):
        target = destination / path.relative_to(source)
        if path.is_symlink():
            if not target.exists() and not target.is_symlink():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(os.readlink(path))
            continue
        if path.is_dir():
            continue
        if state(target) == 'present':
            continue
        materialize(path)
        if state(path) != 'present':
            raise RuntimeError(f'Cannot migrate {path}: {state(path)}')
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_name(target.name + '.partial')
        shutil.copy2(path, temp)
        if sha256(temp) != sha256(path):
            raise RuntimeError(f'Migration checksum mismatch: {path}')
        temp.replace(target)

def install_nemo():
    archive = CACHE / 'nemo-speech-0.2.0-macos-aarch64-metal.tar.gz'
    digest = '5cb02ba7c04f0b5585ce5cde9c830be5f0b7dfb4c83083c500109c381b4f2da9'
    if state(archive, digest) != 'present':
        download('https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.2.0/' + archive.name, digest, archive)
    with tempfile.TemporaryDirectory(dir=CACHE) as temp:
        with tarfile.open(archive) as tar:
            tar.extractall(temp, filter='data')
        root = Path(temp)
        children = list(root.iterdir())
        if len(children) == 1 and children[0].is_dir(): root = children[0]
        stage = HOME / ('.nemo-install-' + uuid.uuid4().hex)
        backup = HOME / ('.nemo-previous-' + uuid.uuid4().hex)
        shutil.copytree(root, stage, symlinks=True)
        destination = HOME/'nemo'
        if destination.exists(): destination.rename(backup)
        try: stage.rename(destination)
        except Exception:
            if backup.exists(): backup.rename(destination)
            raise
        if backup.exists(): shutil.rmtree(backup)


def specs():
    result = []
    for name, repo, rev, digest in [
        ('Qwen3.5-2B-Q4_K_M.gguf','unsloth/Qwen3.5-2B-GGUF','f6d5376be1edb4d416d56da11e5397a961aca8ae','aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223'),
        ('gemma-4-E2B_q4_0-it.gguf','google/gemma-4-E2B-it-qat-q4_0-gguf','675cff42a74c774d6cb76f76d8eacb49b48c9b93','fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634'),
        ('vision/mmproj-gemma-4-E2B-it-Q8_0.gguf','ggml-org/gemma-4-E2B-it-GGUF','b4243c156154b6dca9324415f8c7ccc098b4aed1','9406f99c16d68cda4f1f0552192dcc99021ea1fc6d2fd50b1dc3ccf30d04b292'),
        ('vision/gemma-4-E2B-it-Q4_0.gguf','ggml-org/gemma-4-E2B-it-GGUF','b4243c156154b6dca9324415f8c7ccc098b4aed1','8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52')]:
        result.append(('models/'+name, digest, f'https://huggingface.co/{repo}/resolve/{rev}/{Path(name).name}'))
    for name, repo, rev, digest in [
        ('nemotron-3.5-asr-streaming-0.6b.q8_0.gguf','nvidia/nemotron-3.5-asr-streaming-0.6b','1c8deaecc64b91f034d73e08dd8b64625eb3395d','a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae'),
        ('Nemotron-3-Diarization.q8_0.gguf','nvidia/Nemotron-3-Diarization','f667ed73aee57d40cc39428eb768b4fd87a0a29e','08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1')]:
        result.append(('models/'+name,digest,f'https://huggingface.co/{repo}/resolve/{rev}/{name}'))
    rev = (META/'fluidaudio/MODEL-REVISION.txt').read_text().strip()
    for name, digest in json.loads((META/'fluidaudio/MODEL-SHA256.json').read_text()).items():
        result.append(('models/'+name,digest,f'https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/{rev}/{name}'))
    embedding = json.loads((META/'embeddinggemma2/MODEL-SHA256.json').read_text())
    for part in ['text', 'audio', 'vision']:
        item = embedding[part]
        for name, digest in item['files'].items():
            if '.mlpackage/' not in name:
                result.append(('models/embeddinggemma-2-coreml/'+name, digest,
                               f"https://huggingface.co/{embedding['repository']}/resolve/{item['revision']}/{name}"))
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--all-models', action='store_true', help='also fetch the alternate Gemma title model')
    parser.add_argument('--source', action='append', default=[])
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error('Python 3.12 or newer is required')
    HOME.mkdir(parents=True, exist_ok=True); CACHE.mkdir(parents=True, exist_ok=True)
    if not args.check:
        (HOME/'.python-path').write_text(sys.executable + '\n')
    legacy = ROOT/'.runtime'
    if not args.check and (ROOT/'Package.swift').is_file() and not legacy.exists() and not legacy.is_symlink():
        legacy.symlink_to(HOME, target_is_directory=True)
    with (HOME/'.doctor.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        log(f'Runtime home: {HOME}')
        errors = []
        receipt_file = HOME/'checksums.json'
        receipts = json.loads(receipt_file.read_text()) if state(receipt_file) == 'present' else {}
        corrupt = []
        for name, expected in receipts.items():
            if state(HOME/name, expected) != 'present':
                corrupt.append(name)
                log(f'{name}: {state(HOME/name, expected)}')
        if not args.check:
            # A corrupt compiled graph must be rebuilt from its pinned source package.
            for name in corrupt:
                if '.mlmodelc/' in name and name.startswith('models/embeddinggemma-2-coreml/'):
                    compiled = name.split('.mlmodelc/')[0] + '.mlmodelc'
                    shutil.rmtree(HOME/compiled, ignore_errors=True)
        if not args.check:
            migrate_existing = os.environ.get('WORKSCRIBE_MIGRATE_LEGACY', '1') == '1'
            sources = ([ROOT/'.runtime'] if migrate_existing else []) + list(map(Path,args.source))
            if migrate_existing and (ROOT/'.git').is_file():
                common = subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--git-common-dir'],text=True).strip()
                sources.append((ROOT/common).resolve().parent/'.runtime')
            bundled_models = ROOT.parent/'Models'
            if migrate_existing and bundled_models.is_dir():
                try: migrate(bundled_models, HOME/'models')
                except Exception as e: log(f'Bundled migration deferred: {e}')
            for source in sources:
                try: migrate(source)
                except Exception as e: log(f"Migration deferred: {e}")
            for model, rev in [('nemotron-3.5-asr-streaming-0.6b','1c8deaecc64b91f034d73e08dd8b64625eb3395d'),('Nemotron-3-Diarization','f667ed73aee57d40cc39428eb768b4fd87a0a29e')]:
                cache = Path.home()/'Library/Caches/NeMoSpeech/models/nvidia'/model/rev
                for p in (cache.glob('*.gguf') if migrate_existing else []):
                    dest=HOME/'models'/p.name
                    if state(dest) != 'present':
                        try:
                            materialize(p)
                            dest.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copy2(p,dest)
                        except Exception as e: log(f'Cache copy deferred: {e}')
            if state(HOME/'nemo') != 'present' or any(n.startswith('nemo/') for n in corrupt):
                try:
                    install_nemo()
                    receipts = {k:v for k,v in receipts.items() if not k.startswith('nemo/')}
                except Exception as e: errors.append(str(e)); log(f'Native runtime repair failed: {e}')
        for name, digest, url in specs():
            dest = HOME/name; status=state(dest,digest)
            # Gemma title is an optional alternate; do not fetch it unless installed.
            optional = not args.all_models and name.endswith('gemma-4-E2B_q4_0-it.gguf') and os.environ.get('WORKSCRIBE_TITLE_MODEL', 'qwen35') != 'gemma4'
            log(f'{name}: {status}')
            if args.check and status != 'present' and not (optional and status == 'missing'):
                errors.append(f'{name}: {status}')
            if status != 'present' and not args.check and not (optional and status=='missing'):
                try: download(url,digest,dest)
                except Exception as e: errors.append(str(e)); log(f'Repair failed: {e}')
        embedding=HOME/'models/embeddinggemma-2-coreml'
        for folder in ['EmbeddingGemma2Text.mlmodelc','EmbeddingGemma2Audio.mlmodelc','EmbeddingGemma2Vision.mlmodelc']:
            log(f'{folder}: {state(embedding/folder)}')
            if args.check and state(embedding/folder) != 'present': errors.append(f'{folder}: {state(embedding/folder)}')
        if not args.check:
            # Imported compiled graphs have no upstream file digest; rebuild once from pinned source.
            for folder in ['EmbeddingGemma2Text.mlmodelc', 'EmbeddingGemma2Audio.mlmodelc', 'EmbeddingGemma2Vision.mlmodelc']:
                prefix = 'models/embeddinggemma-2-coreml/' + folder + '/'
                if not any(name.startswith(prefix) for name in receipts):
                    (embedding/folder/'workscribe-revision').unlink(missing_ok=True)
            try: subprocess.run([sys.executable,str(ROOT/'scripts/prepare-embedding-model.py'),'--audio','--vision'],check=True)
            except Exception as e: errors.append(str(e)); log(f'Embedding repair failed: {e}')
        if not args.check and (state(HOME/'models/vision/bin/image-caption') != 'present' or any(n.startswith('models/vision/lib/') or n == 'models/vision/bin/image-caption' for n in corrupt)):
            try: subprocess.run(['/bin/bash', str(ROOT/'scripts/prepare-image-model.sh')], check=True)
            except Exception as e: errors.append(str(e)); log(f'Image helper repair failed: {e}')
        for name in ['nemo','models/vision/bin/image-caption','models/vision/lib','models/vision','models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf','models/Nemotron-3-Diarization.q8_0.gguf']:
            status=state(HOME/name); log(f'{name}: {status}')
            if status != 'present': errors.append(f'{name}: {status} (install native runtime using README)')
        log(f'speaker (legacy, unused): {state(HOME/"speaker")}')
        if args.check:
            errors.extend(f'{name}: wrong hash or missing' for name in corrupt)
        else:
            # Do not bless corruption of an unrepairable legacy runtime.
            for name in corrupt:
                if name.startswith('speaker/') and state(HOME/name, receipts[name]) != 'present':
                    errors.append(f'{name}: needs reinstall (no pinned source)')
        # Record content identities for compiled/local native outputs with no upstream hash manifest.
        if not args.check:
            for p in HOME.rglob('*'):
                if p.is_file() and not p.name.startswith('.') and not p.name.endswith('.partial') and state(p)=='present':
                    name = str(p.relative_to(HOME))
                    if name == 'checksums.json': continue
                    if name not in receipts or not name.startswith('speaker/'):
                        receipts[name]=sha256(p)
            temporary = HOME/'checksums.json.partial'
            temporary.write_text(json.dumps(receipts,indent=2)+'\n')
            temporary.replace(receipt_file)
        for name in ['models/Qwen3.5-2B-Q4_K_M.gguf', 'models/vision', 'models/wespeaker_v2.mlmodelc', 'models/embeddinggemma-2-coreml']:
            log(f'Final {name}: {state(HOME/name)}')
        log('Models ready' if not errors else 'Models need attention · '+ '; '.join(errors))
        return bool(errors)

if __name__ == '__main__':
    sys.exit(main())
