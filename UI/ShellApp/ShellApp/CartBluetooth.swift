import CoreBluetooth
import Foundation

/// Connects to the ESP32 on the cart ("CartArm", see `firmware/src/main.cpp`), reads its
/// distance sensor, and sends it servo angles for the phone arm (used by `ArmController`).
///
/// Flow: Bluetooth turns on → scan for the cart's service → connect → find the DISTANCE and
/// COMMAND characteristics → subscribe to DISTANCE. The ESP32 then pushes a new reading every 100 ms. If the
/// connection drops, it starts scanning again, so walking out of range and back reconnects.
///
/// Bluetooth doesn't work in the Simulator; run on a real iPhone.
final class CartBluetooth: NSObject {
    // Must match SERVICE_UUID, COMMAND_UUID and DISTANCE_UUID in the firmware.
    static let serviceUUID = CBUUID(string: "7d2a0001-4b3c-4f2a-9a61-3c5e8f1b2a10")
    static let commandUUID = CBUUID(string: "7d2a0002-4b3c-4f2a-9a61-3c5e8f1b2a10")
    static let distanceUUID = CBUUID(string: "7d2a0003-4b3c-4f2a-9a61-3c5e8f1b2a10")

    /// Called when the cart connects (true) or disconnects (false).
    var onConnectionChange: (@MainActor (Bool) -> Void)?
    /// Called with each reading in cm. 0 means no echo.
    var onDistance: (@MainActor (Int) -> Void)?

    private var central: CBCentralManager!
    /// iOS cancels a connection to a peripheral nobody holds on to, so keep it here.
    private var cart: CBPeripheral?
    /// Where servo angles are written. Nil until it's found after connecting.
    private var command: CBCharacteristic?
    /// The newest servo angles not sent yet. Only the latest matters: the arm moves to wherever
    /// it was last told.
    private var pendingArm: Data?

    override init() {
        super.init()
        // `queue: nil` delivers every delegate callback on the main thread, which is why the
        // callbacks below can use `MainActor.assumeIsolated`. Creating the manager is also
        // what shows the Bluetooth permission prompt.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Sends the three servo angles (0–180) as 3 raw bytes, the firmware's fastest format.
    /// When the cart isn't connected or Bluetooth's send queue is full, the angles wait and go
    /// out as soon as they can, so a one-off move like facing a shelf isn't lost. A newer move
    /// replaces a waiting one.
    func sendArm(pan: UInt8, tilt1: UInt8, tilt2: UInt8) {
        pendingArm = Data([pan, tilt1, tilt2])
        sendPendingArm()
    }

    private func sendPendingArm() {
        guard let pendingArm, let cart, let command, cart.canSendWriteWithoutResponse else { return }
        cart.writeValue(pendingArm, for: command, type: .withoutResponse)
        self.pendingArm = nil
    }

    private func scan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    private func setConnected(_ isConnected: Bool) {
        MainActor.assumeIsolated { onConnectionChange?(isConnected) }
    }
}

// MARK: Finding and connecting

extension CartBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        } else {
            // Bluetooth turned off or permission denied.
            cart = nil
            command = nil
            setConnected(false)
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        central.stopScan()
        cart = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setConnected(true)
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cart = nil
        scan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cart = nil
        command = nil
        setConnected(false)
        scan()
    }
}

// MARK: Reading the distance

extension CartBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.distanceUUID, Self.commandUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        command = service.characteristics?.first { $0.uuid == Self.commandUUID }
        sendPendingArm()
        guard let distance = service.characteristics?.first(where: { $0.uuid == Self.distanceUUID }) else { return }
        // Subscribe, so each new reading arrives in `didUpdateValueFor` below.
        peripheral.setNotifyValue(true, for: distance)
    }

    /// Bluetooth's send queue has room again.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sendPendingArm()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // The ESP32 sends a uint16_t as 2 bytes, low byte first (little-endian).
        guard let data = characteristic.value, data.count >= 2 else { return }
        let bytes = [UInt8](data)
        let cm = Int(bytes[0]) | Int(bytes[1]) << 8
        MainActor.assumeIsolated { onDistance?(cm) }
    }
}
