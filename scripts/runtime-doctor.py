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

from runtime_doctor_download import download, copy_verified

# Only product assets participate in migration, validation and checksum receipts.
# Retired files already on disk are left untouched, but cannot become runtime requirements.
PRODUCT_FILES = {
    'models/gemma-4-E4B-it-Q4_0.gguf',
    'models/vision/mmproj-gemma-4-E4B-it-Q8_0.gguf',
    'models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf',
    'models/Nemotron-3-Diarization.q8_0.gguf',
}
PRODUCT_TREES = ('nemo', 'models/embeddinggemma-2-coreml', 'models/wespeaker_v2.mlmodelc',
                 'models/vision/bin', 'models/vision/lib')

def product_asset(name):
    return name in PRODUCT_FILES or any(name == root or name.startswith(root + '/') for root in PRODUCT_TREES)

def local_candidates(name, sources):
    """Where a pinned file may already exist on this Mac: a model folder or a runtime-home copy."""
    relative = Path(name)
    for source in sources:
        for candidate in (source/relative.name, source/relative, source/relative.relative_to('models')):
            yield candidate

def install(name, digest, url, sources):
    dest = HOME/name
    for candidate in local_candidates(name, sources):
        if candidate.resolve() != dest.resolve() and state(candidate, digest) == 'present':
            copy_verified(candidate, digest, dest)
            log(f'{name}: installed from {candidate} (SHA-256 verified)')
            return
    download(url, digest, dest)

def materialize(path):
    if state(path) != 'evicted':
        return
    subprocess.run(['/usr/bin/brctl', 'download', str(path)], check=True, timeout=30, stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 120
    while state(path) == 'evicted':
        if time.monotonic() > deadline:
            raise RuntimeError(f'iCloud download timed out: {path}')
        time.sleep(1)

def migrate(source, destination=None, *, product_only=False):
    destination = destination or HOME
    if not source.exists() or source.resolve() == destination.resolve():
        return
    for path in source.rglob('*'):
        target = destination / path.relative_to(source)
        if product_only and not product_asset(str(target.relative_to(HOME))):
            continue
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
        ('gemma-4-E4B-it-Q4_0.gguf','ggml-org/gemma-4-E4B-it-GGUF','b8093469224f83f5c38f691eb906c380e9e63114','a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2'),
        ('vision/mmproj-gemma-4-E4B-it-Q8_0.gguf','ggml-org/gemma-4-E4B-it-GGUF','b8093469224f83f5c38f691eb906c380e9e63114','197f49a93027f9843772bd24a6a9e0be2a32a788de5a3def330e9c585d86edd1')]:
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
    parser.add_argument('--source', action='append', default=[])
    parser.add_argument('--model-source', action='append', default=[], type=Path,
                        help='a folder holding pinned model files (e.g. an earlier download); each is installed only if its SHA-256 matches')
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
        receipts = {name: digest for name, digest in receipts.items() if product_asset(name)}
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
                try: migrate(bundled_models, HOME/'models', product_only=True)
                except Exception as e: log(f'Bundled migration deferred: {e}')
            for source in sources:
                try: migrate(source, product_only=True)
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
        model_sources = args.model_source + [Path('/private/tmp/claude-501/llm-models/gemma-4-e4b-gguf')] + [Path(p) for p in os.environ.get('WORKSCRIBE_MODEL_SOURCES', '').split(os.pathsep) if p]
        for name, digest, url in specs():
            dest = HOME/name; status=state(dest,digest)
            log(f'{name}: {status}')
            if args.check and status != 'present':
                errors.append(f'{name}: {status}')
            if status != 'present' and not args.check:
                try: install(name, digest, url, model_sources)
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
        if args.check:
            errors.extend(f'{name}: wrong hash or missing' for name in corrupt)
        # Record content identities for compiled/local native outputs with no upstream hash manifest.
        if not args.check:
            for p in HOME.rglob('*'):
                name = str(p.relative_to(HOME))
                if not product_asset(name):
                    continue
                if p.is_file() and not p.name.startswith('.') and not p.name.endswith('.partial') and state(p)=='present':
                    receipts[name] = sha256(p)
            temporary = HOME/'checksums.json.partial'
            temporary.write_text(json.dumps(receipts,indent=2)+'\n')
            temporary.replace(receipt_file)
        for name in ['models/gemma-4-E4B-it-Q4_0.gguf', 'models/vision', 'models/wespeaker_v2.mlmodelc', 'models/embeddinggemma-2-coreml']:
            log(f'Final {name}: {state(HOME/name)}')
        log('Models ready' if not errors else 'Models need attention · '+ '; '.join(errors))
        return bool(errors)

if __name__ == '__main__':
    sys.exit(main())
