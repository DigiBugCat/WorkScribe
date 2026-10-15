"""Shared runtime locations and pre-read checks. Never read an SF_DATALESS file."""
import hashlib
import json
import os
from pathlib import Path

HOME = Path(os.environ.get('WORKSCRIBE_RUNTIME_HOME', Path.home() / 'Library/Application Support/WorkScribe/Runtime')).expanduser()
CACHE = Path(os.environ.get('WORKSCRIBE_RUNTIME_CACHE', Path.home() / 'Library/Caches/WorkScribe/Runtime')).expanduser()
DATALESS = 0x40000000
_hash_cache = {}

def state(path, expected=None, stat_fn=None):
    path = Path(path)
    try:
        info = (stat_fn or (lambda p: p.stat()))(path)
    except FileNotFoundError:
        return 'missing'
    if getattr(info, 'st_flags', 0) & DATALESS:
        return 'evicted'
    if path.is_dir():
        children = list(path.rglob('*'))
        files = [p for p in children if p.is_file()]
        if not files:
            return 'missing'
        for child in children:
            try:
                child_info = child.stat()
            except FileNotFoundError:
                return 'missing'
            if getattr(child_info, 'st_flags', 0) & DATALESS:
                return 'evicted'
        return next((s for p in files if (s := state(p)) != 'present'), 'present')
    if info.st_size == 0:
        return 'wrong hash'
    if expected and sha256(path) != expected:
        return 'wrong hash'
    return 'present'

def sha256(path):
    path = Path(path)
    info = path.stat()
    if getattr(info, 'st_flags', 0) & DATALESS:
        raise RuntimeError(f'{path}: evicted')
    key = (str(path), info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if key in _hash_cache:
        return _hash_cache[key]
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''):
            h.update(block)
    digest = h.hexdigest()
    _hash_cache[key] = digest
    return digest

def require(path, expected=None):
    status = state(path, expected)
    if status != 'present':
        raise RuntimeError(f'{path}: {status}; run WorkScribe --doctor')


def verified_tree(path):
    """Validate prior compiled-output receipts as well as metadata before reuse."""
    path = Path(path)
    if state(path) != 'present':
        return False
    receipt = HOME / 'checksums.json'
    if state(receipt) != 'present':
        return True
    for name, digest in json.loads(receipt.read_text()).items():
        candidate = HOME / name
        if candidate.is_relative_to(path) and state(candidate, digest) != 'present':
            return False
    return True
