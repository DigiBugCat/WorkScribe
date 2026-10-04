#!/usr/bin/env python3
"""Experimental Apple-silicon compatibility probe; not a production SDK port."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sdk-root", type=Path, required=True, help="Unmodified plaud-sdk-public/sdk/ios directory")
parser.add_argument("--output-dir", type=Path, default=Path.home() / "Library/Caches/WorkScribe/PlaudNativeLab")
args = parser.parse_args()
root = Path(__file__).resolve().parent
build = args.output_dir.resolve()
framework = build / "Frameworks/PlaudBleSDK.framework"
source = args.sdk_root.resolve() / "PlaudBleSDK.framework"
original = source / "PlaudBleSDK"
source_hash = hashlib.sha256(original.read_bytes()).hexdigest()
shutil.copytree(source, framework, dirs_exist_ok=True)


def run(label, command):
    result = subprocess.run(command, text=True, capture_output=True)
    (build / f"{label}.txt").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{label} failed; see {build / (label + '.txt')}")
    return result.stdout


# Same arm64 machine code. Change the Mach-O platform declaration on a COPY.
run("retarget", ["xcrun", "vtool", "-set-build-version", "macos", "14.0", "26.5",
                 "-replace", "-output", str(framework / "PlaudBleSDK"), str(original)])
header = framework / "Headers/PlaudBleSDK.h"
header.write_text(header.read_text().replace("#import <UIKit/UIKit.h>", ""))
modules = framework / "Modules/PlaudBleSDK.swiftmodule"
interface = (modules / "arm64-apple-ios.swiftinterface").read_text()
interface = interface.replace("-target arm64-apple-ios14.0", "-target arm64-apple-macos14.0")
interface = interface.replace("import UIKit\n", "")
(modules / "arm64-apple-macos.swiftinterface").write_text(interface)
plist = framework / "Info.plist"
metadata = plistlib.loads(plist.read_bytes())
metadata["CFBundleSupportedPlatforms"] = ["MacOSX"]
plist.write_bytes(plistlib.dumps(metadata))
run("attributes", ["xattr", "-cr", str(framework)])
run("sign", ["codesign", "--force", "--sign", "-", str(framework)])
run("build", ["xcrun", "swiftc", "-target", "arm64-apple-macos14.0",
              "-F", str(framework.parent), "-framework", "PlaudBleSDK",
              "-Xlinker", "-rpath", "-Xlinker", str(framework.parent),
              str(root / "probe.swift"), "-o", str(build / "probe")])
output = run("run", [str(build / "probe")])
result = {"sdk_version": metadata.get("CFBundleShortVersionString"),
          "original_binary_sha256": source_hash,
          "native_swift_build_and_execution": "passed",
          "bluetooth_scanning": "not tested", "authentication": "not tested",
          "live_audio": "not tested", "output": output}
(build / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(output, end="")
print("Results:", build / "result.json")
