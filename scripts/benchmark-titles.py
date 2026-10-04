"""Compare the two candidate title models using synthetic, non-private transcripts."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
executable = root / '.build/release/WorkScribe'
cases = {
    'release': 'We need to ship the desktop recorder on Friday. Sam will test system audio and microphone capture. Priya will finish the installer. If the permission issue is still open Thursday, we will postpone the release rather than ship a broken recorder.',
    'budget': 'The cloud bill rose because staging workers stayed running overnight. We agreed to shut down idle workers and set a monthly budget alert. The immediate target is reducing staging compute costs, without changing production capacity.',
    'design': 'Can you hear me? Yes, good morning. How was your weekend? Fine, thanks. Today we need to decide how transcript search should work. Results need timestamps and speaker labels. Let us put the search field above the meeting list and show matching passages under each recording.',
    'tentative': 'We discussed moving customer data to another provider, but no migration was approved. The next step is a security review and a small performance comparison. We must keep the current provider until both reviews are done. This is only an evaluation.',
    'personal': 'We are planning the camping trip. It may rain Saturday, so we should bring the waterproof tent and choose a campsite with a covered picnic area. Maya will book the campsite, and I will bring the stove and groceries.',
}
models = {'gemma4': 'gemma-4-E2B_q4_0-it.gguf', 'qwen35': 'Qwen3.5-2B-Q4_K_M.gguf'}
results = []
for model, filename in models.items():
    for name, transcript in cases.items():
        process = subprocess.run(['/usr/bin/time','-l',str(executable),'--verify-title',transcript,
                                  '--title-model',model,'--model-path',str(root/'.runtime/models'/filename)],
                                 capture_output=True,text=True,timeout=120)
        row = {'model': model, 'case': name, 'exit': process.returncode}
        if process.returncode == 0:
            row.update(json.loads(process.stdout))
        else:
            row['error'] = process.stderr[-2000:]
        match = re.search(r'(\d+)\s+peak memory footprint',process.stderr)
        if match: row['peak_bytes'] = int(match.group(1))
        results.append(row)
        print(json.dumps(row),flush=True)
        (root/'.build/title-benchmark.json').write_text(json.dumps(results,indent=2))
