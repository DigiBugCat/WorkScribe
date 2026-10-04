import Foundation
import PlaudBleSDK

// Exercise real SDK code with synthetic PCM. Does not initialize Bluetooth,
// scan, authenticate, bind, or connect to any device.
let samples = [Int16](repeating: 1000, count: 320)
let data = samples.withUnsafeBytes { Data($0) }
let level = JXRecordVolumer.shared.averageVolume(data)
precondition(level > 0, "Synthetic non-silent PCM should produce a positive level")
print("Native Swift meter:", level)
print("BLE type:", BleAgent.self)
