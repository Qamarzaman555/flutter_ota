/// Value emitted on [OtaPackage.percentageStream] when an update is cancelled.
const int cancelledValue = -1;

/// Value emitted on [OtaPackage.percentageStream] when an update fails because
/// of a BLE error (e.g. the device disconnects or a write fails with a GATT
/// error). The package emits this instead of throwing so the app does not crash.
const int failedValue = -2;

/// Maximum size, in bytes, of a single BLE characteristic write.
///
/// BLE caps a single characteristic write at 512 bytes — the maximum attribute
/// length defined in the Bluetooth spec, which `flutter_blue_plus` also enforces
/// on both Android and iOS. Writes larger than this fail at runtime, so
/// [Esp32OtaPackage.updateFirmware] rejects any chunk that would exceed it.
const int maxMtuSize = 512;

/// Number of header bytes the Arduino OTA protocol prepends to every data
/// packet (`0xFB` marker + part index — see [ArduinoOtaProtocol]).
///
/// Because of this overhead an Arduino packet on the wire is `mtuSize + 2`
/// bytes, so the largest usable `mtuSize` for the Arduino path is
/// [maxMtuSize] - [arduinoHeaderSize].
const int arduinoHeaderSize = 2;
