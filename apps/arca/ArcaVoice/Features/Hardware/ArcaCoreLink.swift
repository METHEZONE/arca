#if os(iOS)
@preconcurrency import CoreBluetooth
import Foundation
import Observation

struct ArcaCoreDeviceStatus: Equatable, Sendable {
    let face: UInt8
    let recordingMode: UInt8
    let hasSDCard: Bool
    let wifiConnected: Bool
    let streaming: Bool
    let charging: Bool
    let sessionSeconds: UInt32
    let queuedFiles: UInt16
    let batteryPercent: Int?
    let levelDB: Int8

    var isRecording: Bool { recordingMode != 0 }
}

struct ArcaCoreWiFiStatus: Equatable, Sendable {
    let state: UInt8
    let savedNetworkCount: Int
    let rssi: Int?
    let ssid: String

    var isConnected: Bool { state == 5 }
}

/// Persistent CoreBluetooth link between the iPhone app and ARCA Core.
///
/// BLE carries control, live status, and Wi-Fi provisioning. Finished WAV files
/// stay on the SD card until the device reaches a saved 2.4 GHz Wi-Fi network
/// (including an iPhone Personal Hotspot) and uploads them directly.
@MainActor
@Observable
final class ArcaCoreLink: NSObject {
    static let shared = ArcaCoreLink()

    enum ConnectionState: Equatable {
        case bluetoothOff
        case searching
        case connecting
        case discovering
        case ready
        case unavailable(String)
    }

    enum Command: UInt8 {
        case recordToggle = 0x02
        case recordStop = 0x03
        case mark = 0x04
        case syncNow = 0x05
        case screenWake = 0x12
    }

    private enum UUIDs {
        static let service = CBUUID(string: "7A9C0000-A5C1-4B2E-9D31-0A5C41524341")
        static let status = CBUUID(string: "7A9C0001-A5C1-4B2E-9D31-0A5C41524341")
        static let control = CBUUID(string: "7A9C0002-A5C1-4B2E-9D31-0A5C41524341")
        static let wifiSetup = CBUUID(string: "7A9C0004-A5C1-4B2E-9D31-0A5C41524341")
        static let wifiStatus = CBUUID(string: "7A9C0005-A5C1-4B2E-9D31-0A5C41524341")
    }

    private static let savedPeripheralKey = "arcaCorePeripheralIdentifier"
    private static let restorationIdentifier = "com.thezone.arca.voice.core-link"

    private(set) var state: ConnectionState = .searching
    private(set) var deviceName = "ARCA Core"
    private(set) var deviceStatus: ArcaCoreDeviceStatus?
    private(set) var wifiStatus: ArcaCoreWiFiStatus?
    private(set) var lastError: String?
    private(set) var lastProvisionedSSID: String?
    private(set) var lastUploadCompletedAt: Date?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var statusCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var wifiSetupCharacteristic: CBCharacteristic?
    private var wifiStatusCharacteristic: CBCharacteristic?
    private var started = false

    private override init() {
        super.init()
    }

    func start() {
        guard !started else {
            scanOrReconnect()
            return
        }
        started = true
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
    }

    func reconnect() {
        lastError = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            scanOrReconnect()
        }
    }

    func send(_ command: Command) {
        guard let peripheral, let controlCharacteristic, state == .ready else {
            lastError = "ARCA Core가 아직 연결되지 않았습니다."
            return
        }
        peripheral.writeValue(Data([command.rawValue]), for: controlCharacteristic, type: .withResponse)
    }

    func provisionWiFi(ssid: String, password: String) {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ssidData = cleanSSID.data(using: .utf8), !ssidData.isEmpty,
              ssidData.count <= 32 else {
            lastError = "Wi-Fi 이름은 UTF-8 기준 1~32바이트여야 합니다."
            return
        }
        guard let passwordData = password.data(using: .utf8), passwordData.count <= 63 else {
            lastError = "Wi-Fi 비밀번호는 UTF-8 기준 최대 63바이트입니다."
            return
        }
        guard passwordData.isEmpty || passwordData.count >= 8 else {
            lastError = "Wi-Fi password must be 8–63 bytes (or empty for an open network)."
            return
        }
        guard let peripheral, let wifiSetupCharacteristic, state == .ready else {
            lastError = "먼저 ARCA Core를 연결해 주세요."
            return
        }

        var payload = Data([1, UInt8(ssidData.count), UInt8(passwordData.count)])
        payload.append(ssidData)
        payload.append(passwordData)
        lastError = nil
        lastProvisionedSSID = cleanSSID
        peripheral.writeValue(payload, for: wifiSetupCharacteristic, type: .withResponse)
    }

    private func scanOrReconnect() {
        guard central?.state == .poweredOn else { return }
        if let raw = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let identifier = UUID(uuidString: raw),
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(known)
            return
        }
        state = .searching
        central.scanForPeripherals(withServices: [UUIDs.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }

    private func connect(_ candidate: CBPeripheral) {
        guard peripheral?.identifier != candidate.identifier || candidate.state == .disconnected else { return }
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        state = .connecting
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func resetCharacteristics() {
        statusCharacteristic = nil
        controlCharacteristic = nil
        wifiSetupCharacteristic = nil
        wifiStatusCharacteristic = nil
        deviceStatus = nil
        wifiStatus = nil
    }

    private func finishDiscoveryIfReady() {
        guard statusCharacteristic != nil,
              controlCharacteristic != nil,
              wifiSetupCharacteristic != nil,
              wifiStatusCharacteristic != nil else { return }
        state = .ready
        lastError = nil
    }

    private func parseDeviceStatus(_ data: Data) {
        guard data.count >= 12, data[0] == 1 else { return }
        let flags = data[3]
        let next = ArcaCoreDeviceStatus(
            face: data[1],
            recordingMode: data[2],
            hasSDCard: flags & 0x01 != 0,
            wifiConnected: flags & 0x02 != 0,
            streaming: flags & 0x04 != 0,
            charging: flags & 0x08 != 0,
            sessionSeconds: data.uint32LE(at: 4),
            queuedFiles: data.uint16LE(at: 8),
            batteryPercent: data[10] == 255 ? nil : Int(data[10]),
            levelDB: Int8(bitPattern: data[11])
        )
        if let previous = deviceStatus, previous.queuedFiles > 0, next.queuedFiles == 0 {
            lastUploadCompletedAt = .now
        }
        deviceStatus = next
    }

    private func parseWiFiStatus(_ data: Data) {
        guard data.count >= 37, data[0] == 1 else { return }
        let length = min(Int(data[4]), 32)
        let ssid = String(data: data.subdata(in: 5..<(5 + length)), encoding: .utf8) ?? ""
        let rawRSSI = Int8(bitPattern: data[3])
        wifiStatus = ArcaCoreWiFiStatus(
            state: data[1],
            savedNetworkCount: Int(data[2]),
            rssi: rawRSSI == .min ? nil : Int(rawRSSI),
            ssid: ssid
        )
    }
}

extension ArcaCoreLink: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanOrReconnect()
        case .poweredOff:
            state = .bluetoothOff
        case .unauthorized:
            state = .unavailable("Bluetooth 권한이 필요합니다.")
        case .unsupported:
            state = .unavailable("이 iPhone은 Bluetooth LE를 지원하지 않습니다.")
        default:
            state = .searching
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        deviceName = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "ARCA Core"
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        state = .discovering
        resetCharacteristics()
        peripheral.discoverServices([UUIDs.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = error?.localizedDescription ?? "ARCA Core 연결에 실패했습니다."
        self.peripheral = nil
        resetCharacteristics()
        scanOrReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let error { lastError = error.localizedDescription }
        self.peripheral = nil
        resetCharacteristics()
        scanOrReconnect()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        restored.delegate = self
        if restored.state == .connected {
            state = .discovering
            restored.discoverServices([UUIDs.service])
        }
    }
}

extension ArcaCoreLink: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        peripheral.services?
            .filter { $0.uuid == UUIDs.service }
            .forEach {
                peripheral.discoverCharacteristics(
                    [UUIDs.status, UUIDs.control, UUIDs.wifiSetup, UUIDs.wifiStatus],
                    for: $0
                )
            }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case UUIDs.status:
                statusCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            case UUIDs.control:
                controlCharacteristic = characteristic
            case UUIDs.wifiSetup:
                wifiSetupCharacteristic = characteristic
            case UUIDs.wifiStatus:
                wifiStatusCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == UUIDs.status {
            parseDeviceStatus(data)
        } else if characteristic.uuid == UUIDs.wifiStatus {
            parseWiFiStatus(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
        } else if characteristic.uuid == UUIDs.wifiSetup {
            // The device accepted the encrypted provisioning packet. Actual
            // association success arrives asynchronously in WIFI STATUS.
            lastError = nil
            if let wifiStatusCharacteristic {
                peripheral.readValue(for: wifiStatusCharacteristic)
            }
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
#endif
