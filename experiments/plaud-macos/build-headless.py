#!/usr/bin/env python3
"""Build only the SDK's non-UI audio header/decryption/parser objects for macOS."""
import argparse
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess

p=argparse.ArgumentParser();p.add_argument('--sdk-root',type=Path,required=True)
p.add_argument('--output-dir',type=Path,default=Path.home()/'Library/Caches/WorkScribe/PlaudNativeLab')
a=p.parse_args(); build=a.output_dir.resolve(); objects=build/'headless-objects';objects.mkdir(parents=True,exist_ok=True)
selected=['PlaudEncryptHeader.o','AudioFileDecryptor.o','OggOpusParser.o']
archive=a.sdk_root.resolve()/'PlaudDeviceBasicSDK.framework/PlaudDeviceBasicSDK'
subprocess.run(['ar','-x',str(archive),*selected],cwd=objects,check=True)
for name in selected:
    file=objects/name
    # Original per-file autolink lists include the *entire* iOS framework's UI
    # imports. Remove linker directives, not any executable instructions.
    data=bytearray(file.read_bytes())
    assert struct.unpack_from('<I',data)[0]==0xfeedfacf
    count,size=struct.unpack_from('<II',data,16); offset=32; commands=[]
    for _ in range(count):
        cmd,length=struct.unpack_from('<II',data,offset)
        if cmd!=0x2d: commands.append(bytes(data[offset:offset+length]))
        offset+=length
    replacement=b''.join(commands)
    data[32:32+size]=replacement+b'\0'*(size-len(replacement))
    struct.pack_into('<II',data,16,len(commands),len(replacement));file.write_bytes(data)
    converted=objects/('mac-'+name)
    subprocess.run(['xcrun','vtool','-set-build-version','macos','14.0','26.5','-replace','-output',str(converted),str(file)],check=True)
# These data symbols are import anchors, not executable APIs. Real imported
# functions/classes still have to resolve. The selected objects do not use UIKit.
markers=set()
for name in selected:
    for line in subprocess.check_output(['nm','-u',str(objects/('mac-'+name))],text=True).splitlines():
        symbol=line.strip().split()[-1]
        if symbol.startswith('__swift_FORCE_LOAD_$_'): markers.add(symbol)
(objects/'ImportAnchors.c').write_text('\n'.join(
    f'__attribute__((weak,visibility("hidden"))) const unsigned char anchor_{i} __asm__("{symbol}") = 0;'
    for i,symbol in enumerate(sorted(markers)))+'\n')
subprocess.run(['xcrun','clang','-c','-target','arm64-apple-macos14.0',str(objects/'ImportAnchors.c'),'-o',str(objects/'ImportAnchors.o')],check=True)
folder=build/'Frameworks/PlaudDeviceBasicSDK.framework';folder.mkdir(parents=True,exist_ok=True)
# Suppress SDK logging, which may contain cryptographic payloads. No auth or
# permission implementation is included or replaced in this audio-only subset.
(objects/'NativeLogging.swift').write_text('import Foundation\nimport CryptoKit\nimport Security\nimport PlaudBleSDK\npublic func plaudLog(_ values: Any...) {}\n')
command=['xcrun','swiftc','-swift-version','5','-emit-library','-module-name','PlaudDeviceBasicSDK','-target','arm64-apple-macos14.0','-F',str(build/'Frameworks'),'-framework','PlaudBleSDK','-framework','Foundation','-framework','Security','-framework','CryptoKit','-Xlinker','-install_name','-Xlinker','@rpath/PlaudDeviceBasicSDK.framework/PlaudDeviceBasicSDK',str(objects/'NativeLogging.swift'),str(objects/'ImportAnchors.o'),*[str(objects/('mac-'+x)) for x in selected],'-o',str(folder/'PlaudDeviceBasicSDK')]
r=subprocess.run(command,capture_output=True,text=True);(build/'headless-build.txt').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit(r.stderr)
source=(a.sdk_root/'PlaudDeviceBasicSDK.framework/Modules/PlaudDeviceBasicSDK.swiftmodule/arm64-apple-ios.swiftinterface').read_text()
header_start=source.index('@objc public class PlaudEncryptHeader')
header=source[header_start:source.index('\n}',header_start)+3]
crypto=source[source.index('@_inheritsConvenienceInitializers @objc public class AudioFileDecryptor'):source.index('@objc public enum PlaudDownloadFormat')]
interface='// swift-interface-format-version: 1.0\n// swift-compiler-version: Apple Swift version 6.0.3\n// swift-module-flags: -target arm64-apple-macos14.0 -enable-objc-interop -enable-library-evolution -swift-version 5 -module-name PlaudDeviceBasicSDK\nimport Foundation\nimport PlaudBleSDK\n'+header+crypto
modules=folder/'Modules/PlaudDeviceBasicSDK.swiftmodule';modules.mkdir(parents=True,exist_ok=True)
(modules/'arm64-apple-macos.swiftinterface').write_text(interface)
(folder/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.workscribe.plaud-headless','CFBundleExecutable':'PlaudDeviceBasicSDK','CFBundleName':'PlaudDeviceBasicSDK','CFBundlePackageType':'FMWK','CFBundleVersion':'1','CFBundleSupportedPlatforms':['MacOSX']}))
subprocess.run(['xattr','-cr',str(folder)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(folder)],check=True)
print(folder)
