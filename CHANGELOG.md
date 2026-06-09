# Changelog

All notable changes to the `flutter_ota` package are documented in this file.

## [1.0.0] - 2026-06-08

### Added
- Typed exception hierarchy for OTA failures — `OtaException` (base),
  `EmptyFirmwareException`, and `FirmwareDownloadException` (which carries the
  HTTP `statusCode`) — so callers can handle errors by type instead of matching
  on raw strings.
- Validation that rejects an empty downloaded firmware body (HTTP 200 with
  0 bytes) before chunking.
- Early-fail guard that aborts the update when the firmware is empty, before any
  BLE handshake or writes are sent, so the device is never left mid-update with
  nothing to flash.
- `dispose()` method on `OtaPackage` for resource management; the package also
  disposes itself when an update reaches a terminal state.
- Optional `mtuSize` parameter on `updateFirmware` to control the chunk
  (packet) size used during transfer, honoured by both the ESP-IDF and Arduino
  paths.
- `maxMtuSize` (512) and `arduinoHeaderSize` (2) constants, plus up-front,
  protocol-aware validation of `mtuSize`: it must be between 1 and 512 for
  ESP-IDF, or 1 and 510 for Arduino (which prepends a 2-byte packet header).
  Out-of-range values throw `OtaException` before any BLE writes, instead of
  failing mid-transfer with a GATT error.
- Structured `logger`-based logging, replacing `print` statements.

### Fixed
- Arduino updates now use the caller-supplied `mtuSize`. Previously it was
  ignored in favour of the device-negotiated MTU and hardcoded values (`200`,
  `400`), so the requested chunk size never reached the device.

### Changed
- Refactored the OTA API to use the `UpdateType` and `FirmwareType` enums in
  place of integer codes.
- Firmware loaders now throw the typed exceptions above instead of plain
  `String`s, and rethrow existing `OtaException`s without re-wrapping them.
- Generalised the failure log message from "BLE error" to "OTA update aborted"
  to reflect that it now also covers validation failures.

### Removed
- The unused `service` and UUID parameters from `updateFirmware`.
- Unused helper methods (`getFirmware`, `uint8ListToIntList`) from
  `Esp32OtaPackage`.
- The hardcoded `mtu` field (`400`) on `Esp32OtaPackage`; `sendPart` now takes
  the chunk size as a parameter sourced from `mtuSize`.

## [0.1.15] - 2024-04-18

- Updated dependencies to the latest versions.

## [0.0.5] - 2023-08-08

### Added
- First public release of the `flutter_ota` package on pub.dev.
- Firmware update over Bluetooth Low Energy (BLE) for ESP32.
