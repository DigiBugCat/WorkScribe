import Foundation
import PlaudBleSDK
final class HandoffBLEDelegate: NSObject, BleAgentProtocol {
 var power: ((Bool) -> Void)?
 var devices: (([BleDevice]) -> Void)?
 var bind: ((String?, Int) -> Void)?
 var connection: ((Int) -> Void)?
 var files: (([BleFile]) -> Void)?
 var data: ((Int, Int, Data) -> Void)?
 var complete: (() -> Void)?
 var depair: ((Int) -> Void)?
 var state: (() -> Void)?
 var syncHead: ((Int) -> Void)?
func bleUpdatePowerLowErr() {  }
func bleDeviceDisconnectErr() { connection?(0) }
func bleUDiskErr(funcName: Swift.String) {  }
func bleAppKeyState(result: Swift.Int) {  }
func bleState(powered: Swift.Bool) { power?(powered) }
func bleConnectStage(sn: Swift.String?, stage: Swift.String, detail: Swift.String?) {  }
func bleConnectState(state: Swift.Int) { connection?(state) }
func bleScanResult(bleDevices: [PlaudBleSDK.BleDevice]) { devices?(bleDevices) }
func bleScanOverTime() {  }
func bleHandshakeWait(timeout: Swift.Int) {  }
func bleBind(sn: Swift.String?, status: Swift.Int, protVersion: Swift.Int, timezone: Swift.Int) { bind?(sn, status) }
func bleDeviceName(name: Swift.String?) {  }
func bleHeartbeat(status: Swift.Int) {  }
func blePowerChange(power: Swift.Int, oldPower: Swift.Int) {  }
func bleChargingState(isCharging: Swift.Bool, level: Swift.Int) {  }
func blePenState(state: Swift.Int, privacy: Swift.Int, keyState: Swift.Int, uDisk: Swift.Int, findMyToken: Swift.Int, hasSndpKey: Swift.Int, deviceAccessToken: Swift.Int, versionType: Swift.String, versionCode: Swift.Int) { self.state?() }
func blePenTime(stamp: Swift.Int, timezone: Swift.Int, zoneMin: Swift.Int) {  }
func bleStorage(total: Swift.Int, free: Swift.Int, duration: Swift.Int) {  }
func blePasswordReset(password: Swift.Int) {  }
func bleBacklightDuration(_ duration: Swift.Int) {  }
func bleBacklightBright(_ bright: Swift.Int) {  }
func bleLanguage(_ type: Swift.Int) {  }
func bleRecScene(_ scene: Swift.Int) {  }
func bleRecMode(_ mode: Swift.Int) {  }
func bleVadSensitivity(_ value: Swift.Int) {  }
func bleBatteryMode(_ value: Swift.Int) {  }
func bleVpuGain(_ value: Swift.Int) {  }
func bleMicGain(_ value: Swift.Int) {  }
func bleSwitchHandler(_ id: Swift.Int) {  }
func bleAutoPowerOff(_ value: Swift.Int) {  }
func bleRawWaveEnabled(_ value: Swift.Int) {  }
func bleRecordingAfterDisConnetEnabled(_ value: Swift.Int) {  }
func bleSyncWhenIdleEnabled(_ value: Swift.Int) {  }
func bleIBeaconWakeupEnabled(_ value: Swift.Int) {  }
func bleFindMyState(_ value: Swift.Int) {  }
func bleVPUCLKState(_ value: Swift.Int) {  }
func bleStopRecordingAfterCharging(_ value: Swift.Int) {  }
func bleAutoClear(_ open: Swift.Bool) {  }
func bleVad(_ open: Swift.Bool) {  }
func bleDepair(_ status: Swift.Int) { depair?(status) }
func bleWiFiOpen(_ status: Swift.Int, _ wifiName: Swift.String, _ wholeName: Swift.String, _ wifiPass: Swift.String) {  }
func bleWiFiClose(_ status: Swift.Int) {  }
func bleSetWiFiSsid(status: Swift.Int) {  }
func bleGetWiFiSsid(status: Swift.Int, ssid: Swift.String?) {  }
func bleVoiceAbnormal(status: Swift.Int) {  }
func bleWebsocketProfile(_ type: Swift.Int, _ conent: Swift.String?) {  }
func bleWebsocketTest(_ status: Swift.Int) {  }
func bleRecordStart(sessionId: Swift.Int, start: Swift.Int, status: Swift.Int, scene: Swift.Int, startTime: Swift.Int) {  }
func bleRecordStop(sessionId: Swift.Int, reason: Swift.Int, fileExist: Swift.Bool, fileSize: Swift.Int) {  }
func bleRecordPause(sessionId: Swift.Int, reason: Swift.Int, fileExist: Swift.Bool, fileSize: Swift.Int) {  }
func bleRecordResume(sessionId: Swift.Int, start: Swift.Int, status: Swift.Int, scene: Swift.Int, startTime: Swift.Int) {  }
func bleLedState(onOff: Swift.Int) {  }
func bleSetLedState(onOff: Swift.Int) {  }
func bleFileList(bleFiles: [PlaudBleSDK.BleFile]) { files?(bleFiles) }
func bleSyncFileHead(sessionId: Swift.Int, status: Swift.Int) { syncHead?(status) }
func bleSyncFileTail(sessionId: Swift.Int, crc: Swift.Int) {  }
func bleMarking(sessionId: Swift.Int, status: Swift.Int, markList: [Swift.UInt32]) {  }
func bleGetRecordMarkingTags(uid: Swift.Int, totals: Swift.Int, index: Swift.Int, tags: [PlaudBleSDK.BleRecordMarkingTag]) {  }
func bleAngles(pitchAngle: Swift.Float, rollbackAngle: Swift.Float, yawAngle: Swift.Float) {  }
func bleDataComplete() { complete?() }
func bleData(sessionId: Swift.Int, start: Swift.Int, data: Foundation.Data) { self.data?(sessionId, start, data) }
func deviceLogData(start: Swift.Int, data: Foundation.Data, logType: Swift.Int) {  }
func blePcmData(sessionId: Swift.Int, millsec: Swift.Int, pcmData: Foundation.Data, isMusic: Swift.Bool) {  }
func bleDecodeFail(start: Swift.Int) {  }
func bleSyncFileStop() {  }
func bleDeleteFile(sessionId: Swift.Int, status: Swift.Int) {  }
func bleFotaResult(uid: Swift.Int, status: Swift.Int, errmsg: Swift.String?) {  }
func bleFotaPackReq(uid: Swift.Int, start: Swift.Int, end: Swift.Int) {  }
func bleFotaPackFin(uid: Swift.Int, status: Swift.Int, errmsg: Swift.String?) {  }
func bleOtaDataSendFail() {  }
func bleRate(lossRate: Swift.Double, rate: Swift.Int, instantRate: Swift.Int) {  }
func blePrivacy(privacy: Swift.Int) {  }
func bleClearAllFile(status: Swift.Int) {  }
func bleDeviceStatus(status: [Swift.UInt8]) {  }
func bleSyncOtaFileInfo(uid: Swift.UInt32, start: Swift.UInt32, end: Swift.UInt32, toVersion: Swift.UInt32, toVersionType: Swift.UInt8, isSilent: Swift.Int, packetCheckOk: Swift.Int) {  }
func bleNewFeature(data: Foundation.Data) {  }
func bleAlarmRec(start: Swift.Int, duration: Swift.Int, repeatMode: Swift.Int) {  }
func bleSetActive(status: Swift.Int) {  }
func onBinaryFileReq(type: Swift.Int, packageOffset: Swift.Int, packageSize: Swift.Int, endStatus: Swift.Int) {  }
func onBinaryFileEnd(result: Swift.Int) {  }
func onSyncIdleWifiConfigReceived(index: Swift.UInt32, ssid: Swift.String, password: Swift.String) {  }
func onSyncIdleWifiConfigSet(result: Swift.Int) {  }
func onSyncIdleWifiListReceived(list: [Swift.UInt32]) {  }
func onSyncIdleWifiDeleteResult(result: Swift.Int) {  }
func onSyncIdleWifiTestStarted(index: Swift.UInt32) {  }
func onSyncIdleWillStart(seconds: Swift.Int) {  }
func onSyncIdleWifiTestResult(index: Swift.UInt32, result: Swift.Int, rawCode: Swift.Int) {  }
func onResetFindmyResult(result: Swift.Int) {  }
func onCommonParamsSetResult(success: Swift.Bool, dataType: Swift.Int, value: Swift.String?) {  }
func onCommonParamsGetResult(success: Swift.Bool, dataType: Swift.Int, value: Swift.String?) {  }
func onSetSoundPlusTokenResult(licenseKey: Swift.String) {  }
func onGetSDFlashCIDResult(cid: Swift.String) {  }
func onGetDeviceLogList(data: Foundation.Data) {  }
func onSyncDeviceLogStart(data: Foundation.Data) {  }
func onSyncDeviceLogStop() {  }
func onSyncDeviceLogEnd(data: Foundation.Data) {  }
func onDeviceLogDeleted(data: Foundation.Data) {  }
}
