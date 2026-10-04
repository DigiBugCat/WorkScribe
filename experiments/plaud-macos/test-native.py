#!/usr/bin/env python3
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent
build=Path.home()/'Library/Caches/WorkScribe/PlaudNativeLab'
fixture=build/'synthetic.ogg'
subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=440:duration=0.4','-ar','16000','-ac','1','-c:a','libopus','-b:a','32k','-vbr','off','-frame_duration','20',str(fixture)],check=True)
command=['xcrun','swiftc','-I',str(root/'Sources/COpus'),'-suppress-warnings','-swift-version','5','-parse-as-library','-target','arm64-apple-macos14.0','-F',str(build/'Frameworks'),'-framework','PlaudBleSDK','-framework','PlaudDeviceBasicSDK','-Xlinker','-rpath','-Xlinker',str(build/'Frameworks')]
command += [str(root/'Sources'/x) for x in ['PlaudAuth.swift','EncryptedStream.swift','NativeAudio.swift','OpusPacketDecoder.swift']]
command += [str(root/'Tests/NativeTests.swift'),'-o',str(build/'native-tests')]
r=subprocess.run(command,capture_output=True,text=True);(build/'native-tests-build.txt').write_text(r.stdout+r.stderr)
if r.returncode: raise SystemExit(r.stderr)
r=subprocess.run([str(build/'native-tests'),str(fixture)],capture_output=True,text=True)
(build/'native-tests-result.txt').write_text(r.stdout+r.stderr)
print(r.stdout,r.stderr);r.check_returncode()
for channels in [1, 2]:
    fixture=build/f'synthetic-vbr-{channels}.ogg'
    subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=440:duration=0.4','-ar','48000','-ac',str(channels),'-c:a','libopus','-b:a','24k','-vbr','on',str(fixture)],check=True)
    r=subprocess.run([str(build/'native-tests'),str(fixture),'require-variable-size'],capture_output=True,text=True)
    print(r.stdout,r.stderr);r.check_returncode()
