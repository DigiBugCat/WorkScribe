import Foundation
import CoreBluetooth
import ObjectiveC
import PlaudBleSDK

/// Lab-only transport diagnostics. Records byte counts and GATT errors, never
/// packet contents, tokens, keys, or audio. Calls the original methods unchanged.
enum BLETrace {
    private static let lock = NSLock()
    private static var events: [String] = []
    private static var installed = false
    static var enabled = false
    static var onChange: (() -> Void)?
    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    static func reset() { lock.lock(); events = []; lock.unlock() }
    static func startSDKDiagnostics() {
        // Custom callbacks replace the SDK's default raw-payload console sink.
        // Only these compile-time labels ever leave the callback.
        let filter: (String) -> Void = { text in
            let labels = ["userRSAPublicKey is null", "user_rsa_public_key_empty",
                          "user_rsa_public_key_invalid", "send-rsa-b-error",
                          "userRSAPrivateKey is null", "RSA-decryption failed",
                          "Failed to convert decrypted data to string", "RSA-decryptedData error",
                          "ChaCha20-Poly1305 decryption failed", "onHandshake ok data count err",
                          "onHandshake data count err", "preFirstHandShake", "send-rsa-b,label",
                          "RSA-decryptedData11", "RSA-decryptedCipherText"]
            for label in labels where text.contains(label) { record("sdk: " + label) }
        }
        BleLogger.shared.setLog(opened: true, logBlock: filter, wlogBlock: filter, sync: true)
    }
    private static func record(_ line: String) {
        guard enabled else { return }
        lock.lock(); events.append(line); events = Array(events.suffix(24)); lock.unlock()
        onChange?()
    }
    static func install() {
        guard !installed else { return }; installed = true
        let write = NSSelectorFromString("writeValue:forCharacteristic:type:")
        if let method = class_getInstanceMethod(CBPeripheral.self, write) {
            typealias Original = @convention(c) (AnyObject, Selector, NSData, CBCharacteristic, Int) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (CBPeripheral, NSData, CBCharacteristic, Int) -> Void = { peripheral, data, characteristic, type in
                record("write \(characteristic.uuid.uuidString) bytes=\(data.length) type=\(type) max=\(peripheral.maximumWriteValueLength(for: CBCharacteristicWriteType(rawValue: type) ?? .withResponse))")
                original(peripheral, write, data, characteristic, type)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        for (name, label) in [("peripheral:didUpdateValueForCharacteristic:error:", "notify"),
                              ("peripheral:didWriteValueForCharacteristic:error:", "write-ack")] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(BleDevice.self, selector) else { continue }
            typealias Original = @convention(c) (AnyObject, Selector, CBPeripheral, CBCharacteristic, NSError?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (BleDevice, CBPeripheral, CBCharacteristic, NSError?) -> Void = { device, peripheral, characteristic, error in
                record("\(label) \(characteristic.uuid.uuidString) bytes=\(characteristic.value?.count ?? 0) error=\(error?.code ?? 0)")
                original(device, selector, peripheral, characteristic, error)
                let agent = BleAgent.shared
                record("state packages=\(agent.secretPackages.count) index=\(agent.secretIndex) count=\(agent.secretCount) key=\(agent.chacha20Key != nil)")
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
