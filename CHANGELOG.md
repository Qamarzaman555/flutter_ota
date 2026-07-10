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
- README section on aligning `BluetoothDevice.requestMtu()` with the `mtuSize`
  passed to `updateFirmware`, including per-protocol wire-size notes for
  ESP-IDF and Arduino.

### Fixed
- Arduino updates now use the caller-supplied `mtuSize`. Previously it was
  ignored in favour of the device-negotiated MTU and hardcoded values (`200`,
  `400`), so the requested chunk size never reached the device.
- Arduino OTA progress for firmware with more than 255 segments: progress now
  uses the full 16-bit segment index from device notifications instead of the
  low byte only, which previously caused progress to wrap above ~4 MB.
- Arduino notification handler no longer throws `RangeError` on empty or short
  device notifications; `0x0F` (complete) and `0xF2` (install start) messages
  are handled safely using only the opcode byte.
- Short or invalid Arduino `0xF1` segment requests (truncated payload or
  out-of-range segment index) now fail the OTA update instead of being silently
  ignored, which could leave the transfer stuck without a terminal
  `failedValue`.
- Unknown Arduino opcodes no longer decode `value[1]`/`value[2]` as a segment
  index or emit misleading progress.
- ESP-IDF control-characteristic reads are guarded against empty responses
  before indexing `value[0]`.

### Changed
- Refactored the OTA API to use the `UpdateType` and `FirmwareType` enums in
  place of integer codes.
- Firmware loaders now throw the typed exceptions above instead of plain
  `String`s, and rethrow existing `OtaException`s without re-wrapping them.
- Generalised the failure log message from "BLE error" to "OTA update aborted"
  to reflect that it now also covers validation failures.
- Removed the unused `mtuSize` parameter from internal Arduino raw file-picker
  loading; Arduino chunking still happens in `ArduinoOtaProtocol` during
  transfer.
- ESP-IDF transfer loop now validates that each pre-chunked payload is ≤
  `mtuSize` before writing, catching internal chunk/handshake mismatches early.

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
