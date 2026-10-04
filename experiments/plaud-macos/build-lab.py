#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--sdk-root',type=Path,required=True)
parser.add_argument("--output-dir",type=Path,default=Path.home()/"Library/Caches/WorkScribe/PlaudNativeLab")
a=parser.parse_args()
root=Path(__file__).resolve().parent
subprocess.run(['python3',str(root/'probe.py'),'--sdk-root',str(a.sdk_root),'--output-dir',str(a.output_dir)],check=True)
subprocess.run(['python3',str(root/'build-headless.py'),'--sdk-root',str(a.sdk_root),'--output-dir',str(a.output_dir)],check=True)
build=a.output_dir.resolve()
interface=(a.sdk_root/'PlaudBleSDK.framework/Modules/PlaudBleSDK.swiftmodule/arm64-apple-ios.swiftinterface').read_text()
protocol=interface.split('@objc public protocol BleAgentProtocol {',1)[1].split('\n}',1)[0]
impl=['import Foundation','import PlaudBleSDK','final class NativeBLEDelegate: NSObject, BleAgentProtocol {',
      'var onPower: ((Bool) -> Void)?','var onDevices: (([BleDevice]) -> Void)?', 'var onBind: ((String?, Int) -> Void)?', 'var onConnection: ((Int) -> Void)?', 'var onStage: ((String,String?) -> Void)?', 'var onStart: ((Int,Int) -> Void)?', 'var onStop: ((Int) -> Void)?', 'var onData: ((Int,Int,Data) -> Void)?', 'var onComplete: (() -> Void)?', 'var onWait: ((Int) -> Void)?', 'var onDiagnostic: ((String) -> Void)?']
for line in protocol.splitlines():
    if 'func ' not in line:continue
    signature=line.strip().replace('@objc optional ','').replace('@objc ','')
    name=re.search(r'func (\w+)',signature).group(1)
    body=''
    if name=='bleState':body='onPower?(powered)'
    elif name=='bleScanResult':body='onDevices?(bleDevices)'
    elif name=='bleConnectState':body='onConnection?(state)'
    elif name=='bleDeviceDisconnectErr':body='onConnection?(0)'
    elif name=='bleBind':body='onBind?(sn,status)'
    elif name=='bleConnectStage':body='onStage?(stage,detail)'
    elif name=='bleRecordStart':body='onStart?(sessionId,status)'
    elif name=='bleRecordStop':body='onStop?(sessionId)'
    elif name=='bleData':body='onData?(sessionId,start,data)'
    elif name=='bleDataComplete':body='onComplete?()'
    elif name=='bleHandshakeWait':body='onWait?(timeout)'
    elif name=='bleAppKeyState':body='onDiagnostic?("app key status: \\(result)")'
    elif name=='blePenState':body='onDiagnostic?("device state: \\(state), version: \\(versionCode)")'
    impl.append(signature+' { '+body+' }')
impl.append('}')
(build/'NativeBLEDelegate.swift').write_text('\n'.join(impl)+'\n')
stage=Path(tempfile.mkdtemp(prefix='plaud-lab-stage-'))
app=stage/'Plaud Mac Lab.app'
for d in ['MacOS','Frameworks']: (app/'Contents'/d).mkdir(parents=True,exist_ok=True)
for framework_name in ['PlaudBleSDK','PlaudDeviceBasicSDK']:
    shutil.copytree(build/f'Frameworks/{framework_name}.framework',app/f'Contents/Frameworks/{framework_name}.framework',dirs_exist_ok=True)
info={'CFBundleIdentifier':'local.workscribe.plaud-lab','CFBundleName':'Plaud Mac Lab','CFBundleExecutable':'PlaudMacLab','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','LSMinimumSystemVersion':'14.0','NSBluetoothAlwaysUsageDescription':'Discover and connect to your Plaud recorder for local audio capture.','NSBluetoothPeripheralUsageDescription':'Discover and connect to your Plaud recorder for local audio capture.','NSHighResolutionCapable':True,'LSMultipleInstancesProhibited':True}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
workspace=root.parents[1]
sdk=workspace/'.runtime/nemo'
cnemo=build/'CNemo';cnemo.mkdir(parents=True,exist_ok=True)
(cnemo/'module.modulemap').write_text('module CNemo { umbrella "'+str(workspace/'Sources/CNemo/include')+'" export * }\n')
subprocess.run(['xcrun','clang','-c',str(workspace/'Sources/CNemo/WorkScribeNemo.c'),'-I',str(workspace/'Sources/CNemo/include'),'-o',str(cnemo/'bridge.o')],check=True)
subprocess.run(['ditto',str(sdk/'lib'),str(app/'Contents/Frameworks')],check=True)
models=app/'Contents/Resources/Models';models.mkdir(parents=True,exist_ok=True)
installed=Path.home()/'Applications/WorkScribe.app/Contents/Resources/Models'
for name in ['nemotron-3.5-asr-streaming-0.6b.q8_0.gguf','Nemotron-3-Diarization.q8_0.gguf']:
    subprocess.run(['cp','-c',str(installed/name),str(models/name)],check=True)
command=['xcrun','swiftc','-I',str(root/'Sources/COpus'),'-swift-version','5','-parse-as-library','-target','arm64-apple-macos14.0','-Xcc','-fmodule-map-file='+str(cnemo/'module.modulemap'),'-L',str(sdk/'lib'),'-lnemo_speech_asr_c','-lc++','-F',str(build/'Frameworks'),'-framework','PlaudBleSDK','-framework','PlaudDeviceBasicSDK','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',*[str(p) for p in sorted((root/'Sources').glob('*.swift'))],str(build/'NativeBLEDelegate.swift'),str(workspace/'Sources/WorkScribe/Runtime.swift'),str(cnemo/'bridge.o'),'-o',str(app/'Contents/MacOS/PlaudMacLab')]
r=subprocess.run(command,text=True,capture_output=True);(build/'lab-build.txt').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit(r.stderr)
subprocess.run(['xattr','-cr',str(app)],check=True)
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
destination=build/'Plaud Mac Lab.app'
if destination.exists(): shutil.move(str(destination),str(stage/'previous.app'))
shutil.move(str(app),str(destination))
print(destination)
