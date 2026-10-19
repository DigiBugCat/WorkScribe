"""Resumable, checksum-verified runtime downloads shared by setup tools."""
import shutil
import subprocess
import time
import urllib.request
import urllib.error
from runtime_home import state

def log(message):
    print(message, flush=True)

def download(url, expected, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.partial')
    if state(partial, expected) == 'present':
        partial.replace(target)
        return
    # Keep partial bytes across interruptions. A server may ignore Range; then restart safely.
    for attempt in range(3):
        try:
            offset = partial.stat().st_size if partial.exists() else 0
            request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
            with urllib.request.urlopen(request, timeout=60) as source:
                resumed = offset and source.status == 206
                total = int(source.headers.get('Content-Length', 0)) + (offset if resumed else 0)
                done = offset if resumed else 0
                last = 0
                with partial.open('ab' if resumed else 'wb') as out:
                    while block := source.read(1024*1024):
                        out.write(block); done += len(block)
                        if time.monotonic() - last > 5:
                            log(f'Getting models ready · {done/1e9:.2f} of {total/1e9:.2f} GB · {target.name}')
                            last = time.monotonic()
            if state(partial, expected) != 'present':
                partial.unlink(missing_ok=True)
                raise RuntimeError(f'Checksum mismatch: {target.name}')
            partial.replace(target)
            return
        except Exception as error:
            if isinstance(error, urllib.error.HTTPError) and error.code == 416:
                partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)




def copy_verified(source, expected, target):
    """Installs a pinned file from a local copy (no network): published only when its SHA-256 matches."""
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.partial')
    partial.unlink(missing_ok=True)
    # An APFS clone costs no space until either copy changes; other volumes get a plain copy.
    if subprocess.run(['/bin/cp', '-c', str(source), str(partial)], stderr=subprocess.DEVNULL).returncode != 0:
        shutil.copyfile(source, partial)
    if state(partial, expected) != 'present':
        partial.unlink(missing_ok=True)
        raise RuntimeError(f'Checksum mismatch: {target.name} from {source}')
    partial.replace(target)
