# flutter_ota — Package Documentation

A Flutter package for performing **Over-The-Air (OTA) firmware updates** on
ESP32 devices over **Bluetooth Low Energy (BLE)**.

- **Package name:** `flutter_ota`
- **Current version:** `1.0.0`
- **Repository:** https://github.com/sparkleo-io/flutter_ota
- **Publisher:** sparkleo.io
- **SDK requirements:** Dart `>=3.8.0 <4.0.0`, Flutter `>=3.32.0`

---

## Table of Contents

1. [What is this package & why it exists](#1-what-is-this-package--why-it-exists)
2. [Main features](#2-main-features)
3. [How to use it](#3-how-to-use-it)
4. [Current package scoring](#4-current-package-scoring)
5. [Changelog — what's new in 1.0.0](#5-changelog--whats-new-in-100)
6. [Future plan](#6-future-plan)

---

## 1. What is this package & why it exists

`flutter_ota` is a Flutter package that lets a mobile app **wirelessly flash new
firmware onto an ESP32 microcontroller using Bluetooth Low Energy (BLE)** — no
USB cable, no serial port, no physical access to the device.

### The problem it solves

ESP32 devices are typically flashed over a wired serial connection during
development. Once a device ships inside a product (a wearable, a sensor, a smart
appliance), you can no longer plug in a cable to update its firmware. The only
practical channel left is the radio the device already uses to talk to the phone:
**BLE**.

Implementing OTA-over-BLE by hand is fiddly: you have to negotiate an MTU, split
the firmware binary into correctly-sized packets, drive the device's OTA state
machine with the right control bytes, track acknowledgements, and translate all
of that into UI progress — while gracefully surviving disconnects mid-transfer.

`flutter_ota` packages all of that into a single, high-level call:

```dart
await otaPackage.updateFirmware(
  device,
  UpdateType.espidf,
  FirmwareType.url,
  uri: 'https://example.com/firmware.bin',
);
```

### Why it was created

- To give Flutter apps a **drop-in, reusable OTA layer** for ESP32 instead of
  re-implementing the BLE byte protocol in every project.
- To support **both major ESP32 firmware ecosystems** — the official **ESP-IDF**
  framework and the **Arduino** framework — which use different OTA protocols on
  the wire.
- To make the update process **observable** (a progress stream) and **safe**
  (typed errors, early validation, crash-free handling of BLE failures).

---

## 2. Main features

### Multiple firmware sources

The firmware binary can come from three different places, selected via the
`FirmwareType` enum:

```33:43:lib/ota_package.dart
enum UpdateType { espidf, arduino }

/// The source from which the firmware binary is loaded.
///
/// * [FirmwareType.assets]: Load the firmware from the app's bundled assets
///   (formerly represented by the integer `1`).
/// * [FirmwareType.filepicker]: Let the user pick the firmware file from the
///   device (formerly represented by the integer `2`).
/// * [FirmwareType.url]: Download the firmware from a URL (formerly represented
///   by the integer `3`).
enum FirmwareType { assets, filepicker, url }
```

- **`FirmwareType.assets`** — a `.bin` bundled in your Flutter app's assets.
- **`FirmwareType.filepicker`** — a file the user picks from device storage.
- **`FirmwareType.url`** — a binary downloaded over HTTP at update time.

### Support for both ESP-IDF and Arduino firmware

The package supports both major ESP32 firmware types — ESP-IDF and Arduino — with an easy-to-use `updateFirmware` method that works for either.

### Optional firmware integrity verification

Pass a `FirmwareIntegrityConfig` to `updateFirmware` to enable any combination
of checks your device (and server) support. Default is none — wire format is
unchanged for existing firmware.

| Feature | Role |
| --- | --- |
| `shaBeforeTransfer` | App SHA-256 vs server digest before BLE |
| `packetCrc16` | CRC-16/Modbus per packet; NACK → retransmit that packet |
| `shaAfterFlash` | Device verifies flash SHA-256 before success/reboot |

```dart
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.url,
  uri: firmwareUrl,
  integrity: FirmwareIntegrityConfig(
    features: {
      IntegrityFeature.shaBeforeTransfer,
      IntegrityFeature.packetCrc16,
      IntegrityFeature.shaAfterFlash,
    },
    expectedSha256Hex: serverSha256Hex,
  ),
);
```

### Real-time progress stream

`percentageStream` emits the update progress (0–100) so the UI can show a
progress bar live:

```70:77:lib/ota_package.dart
  /// Stream to provide progress percentage.
  ///
  /// When an update is cancelled via [cancelUpdate], a value of [cancelledValue]
  /// (`-1`) is emitted so listeners can react to the cancellation. If the update
  /// fails because of a BLE error (e.g. the device disconnects mid-transfer or a
  /// write fails with a GATT error), [failedValue] (`-2`) is emitted instead of
  /// throwing, so the caller can update the UI without the app crashing.
  Stream<int> get percentageStream;
```

Two sentinel values let listeners distinguish terminal outcomes without
try/catch noise in the UI:

```108:114:lib/ota_package.dart
/// Value emitted on [OtaPackage.percentageStream] when an update is cancelled.
const int cancelledValue = -1;

/// Value emitted on [OtaPackage.percentageStream] when an update fails because
/// of a BLE error (e.g. the device disconnects or a write fails with a GATT
/// error). The package emits this instead of throwing so the app does not crash.
const int failedValue = -2;
```

### Configurable, protocol-aware chunk size (`mtuSize`)

You can tune the number of firmware bytes sent per BLE packet. The value is
validated **up front** against the BLE single-write limit (512 bytes), with the
Arduino path reserving 2 bytes for its header — so a bad value throws *before*
any data is sent instead of failing mid-transfer:

```598:606:lib/ota_package.dart
    final int maxChunkSize = updateType == UpdateType.arduino
        ? maxMtuSize - arduinoHeaderSize
        : maxMtuSize;
    if (mtuSize < 1 || mtuSize > maxChunkSize) {
      throw OtaException(
        'mtuSize must be between 1 and $maxChunkSize bytes for '
        '${updateType.name} (got $mtuSize).',
      );
    }
```

### Typed error hierarchy

Setup/loading failures are reported as typed exceptions so callers can branch on
the failure type instead of parsing strings:

```137:172:lib/ota_package.dart
class OtaException implements Exception {
  OtaException(this.message, [this.cause]);

  /// Human-readable description of what went wrong.
  final String message;

  /// The underlying error that caused this exception, if any.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'OtaException: $message'
      : 'OtaException: $message ($cause)';
}

/// Thrown when a firmware source yields no data.
///
/// Examples: an empty asset/file, an empty HTTP response body, or no file
/// selected from the picker. Signals the caller to abort before any OTA writes
/// are sent to the device.
class EmptyFirmwareException extends OtaException {
  EmptyFirmwareException([
    super.message =
        'Firmware is empty. Please provide a valid, non-empty firmware binary.',
  ]);
}

/// Thrown when downloading firmware over HTTP fails (non-200 status, timeout,
/// or network error).
class FirmwareDownloadException extends OtaException {
  FirmwareDownloadException(String message, {this.statusCode, Object? cause})
    : super(message, cause);

  /// The HTTP status code, when the failure was an unsuccessful response.
  final int? statusCode;
}
```

### Early validation of empty firmware

Before any BLE handshake or write, the package aborts if the firmware is empty,
so the device is never left mid-update with nothing to flash:

```635:639:lib/ota_package.dart
        /// Fail early on empty firmware: do NOT start the OTA handshake/writes,
        /// otherwise the device is left mid-update with nothing to flash.
        if (binaryChunks.isEmpty) {
          throw EmptyFirmwareException();
        }
```

### Crash-safe handling of BLE failures

If the device disconnects mid-transfer or a write fails with a GATT error, the
package reports it on the stream (`failedValue`) instead of letting the exception
propagate and crash the app:

```287:296:lib/ota_package.dart
  void _handleUpdateError(Object error) {
    _logger.e(
      'OTA update aborted: Device either returned an error or did not acknowledge the operation. '
      'Some devices may not support acknowledgement.'
      'Please ensure the device firmware supports proper OTA acknowledgement flow.',
    );
    _logger.e('OTA update aborted', error: error);
    firmwareUpdate = false;
    _completeUpdate(_cancelRequested ? cancelledValue : failedValue);
  }
```

### Cancellation support

An in-progress update can be cancelled; the package stops sending data and emits
`cancelledValue`:

```226:234:lib/ota_package.dart
  @override
  Future<void> cancelUpdate() async {
    if (!_isUpdating) return;
    _logger.w('OTA update cancellation requested');
    _cancelRequested = true;
    await subscription?.cancel();
    subscription = null;
    _completeUpdate(cancelledValue);
  }
```

### Self-disposing / leak-safe

When an update reaches a terminal state (success, failure, or cancel) the
package cleans up its own subscription and stream — no dependency on a widget
lifecycle, so the user can navigate freely while the update runs:

```269:278:lib/ota_package.dart
  void _completeUpdate(int value) {
    if (_percentageController.isClosed) return;
    _isUpdating = false;
    // Emit the terminal value first so listeners receive it before the
    // stream's done event, then close.
    _percentageController.add(value);
    subscription?.cancel();
    subscription = null;
    _percentageController.close();
  }
```

### Structured logging

Uses the `logger` package with a colorized `PrettyPrinter`, and suppresses output
in release builds, replacing raw `print` calls.

---

## 3. How to use it

### Step 1 — Install

Add the dependency to `pubspec.yaml`:

```yaml
dependencies:
  flutter_ota: ^1.0.0
```

Then fetch it:

```bash
flutter pub get
```

### Step 2 — Platform setup

Because the package talks over BLE, each platform needs permissions configured.

**iOS** — set the deployment target to 13.0+ in `ios/Podfile` and add usage
descriptions to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to and update the firmware of nearby ESP32 devices.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses Bluetooth to connect to and update the firmware of nearby ESP32 devices.</string>
```

**Android** — add BLE/location/internet permissions to
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>

<!-- Android 11 (API 30) and below -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>

<!-- Android 12 (API 31) and above -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>

<!-- Required when downloading firmware from a URL -->
<uses-permission android:name="android.permission.INTERNET"/>
```

Request the runtime permissions before starting an update.

### Step 3 — Import

```dart
import 'package:flutter_ota/ota_package.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
```

### Step 4 — Connect & locate the OTA characteristics

Use `flutter_blue_plus` to connect to the device and discover its services, then
find the **notify** and **write** characteristics for your firmware's OTA
service. From the example app:

```156:204:example/lib/features/scanningAndConnection/presentation/view/ota_update_page.dart
                    bool characteristicsFound = false;

                    for (BluetoothService service in services) {
                      debugPrint(
                        "In services loop and services lenght is ${services.length}",
                      );
                      if (service.uuid
                              .toString() == //'d6f1d96d-594c-4c53-b1c6-144a1dfde6d8') {
                          'd6f1d96d-594c-4c53-b1c6-144a1dfde6d8') {
                        //arduino uuid
                        debugPrint("service found");
                        final characteristics = service.characteristics;
                        BluetoothCharacteristic? notifyUuid;
                        BluetoothCharacteristic? writeUuid;

                        for (BluetoothCharacteristic c in characteristics) {
                          if (c.uuid
                                  .toString() == //'7ad671aa-21c0-46a4-b722-270e3ae3d830') {
                              '7ad671aa-21c0-46a4-b722-270e3ae3d830') {
                            // arduino
                            notifyUuid = c;
                          }
                          if (c.uuid
                                  .toString() == //'23408888-1f40-4cd8-9b89-ca8d45f8a5b0') {
                              '23408888-1f40-4cd8-9b89-ca8d45f8a5b0') {
                            //arduino
                            writeUuid = c;
                          }
                        }

                        if (notifyUuid != null && writeUuid != null) {
                          if (Platform.isAndroid) {
                            debugPrint("Plateform is andriod");
                            // Request a new MTU size for Android
                            const newMtu = 500;
                            await device.requestMtu(newMtu);

                            // The MTU request was successful, debugPrint the new MTU size
                            debugPrint('New MTU size (Android): $newMtu');
                          } else if (Platform.isIOS) {
                            // Use fixed MTU size of 185 for iOS
                            const newMtu = 185;
                            debugPrint('New MTU size (iOS): $newMtu');
                          }

                          Esp32OtaPackage esp32otaPackage = Esp32OtaPackage(
                            notifyUuid,
                            writeUuid,
                          );
```

> **Note:** The replace the UUIDs above with the actual service/characteristic
> UUIDs of your own ESP32 firmware.

### Step 5 — Create the OTA package

The constructor order is **(notifyCharacteristic, writeCharacteristic)**:

```dart
Esp32OtaPackage otaPackage = Esp32OtaPackage(notifyCharacteristic, writeCharacteristic);
```

### Step 6 — Listen to progress

`percentageStream` is a broadcast stream emitting 0–100, plus the
`cancelledValue` / `failedValue` sentinels. A typical `StreamBuilder`:

```dart
StreamBuilder<int>(
  stream: otaPackage.percentageStream,
  initialData: 0,
  builder: (context, snapshot) {
    final value = snapshot.data ?? 0;
    if (value == cancelledValue) return const Text('Update cancelled');
    if (value == failedValue)    return const Text('Update failed — reconnect');
    return LinearProgressIndicator(value: value / 100);
  },
);
```

### Step 7 — Start the update

Call `updateFirmware`, passing the protocol (`UpdateType`), the source
(`FirmwareType`), and the matching parameters. `uri` is required for every source
except `FirmwareType.filepicker`.

```dart
// ESP-IDF — firmware bundled in assets
await otaPackage.updateFirmware(
  device,
  UpdateType.espidf,
  FirmwareType.assets,
  uri: 'assets/firmware.bin',
  mtuSize: 500, // optional, default 500
);

// Arduino — firmware downloaded from a URL
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.url,
  uri: 'https://example.com/firmware.ino.bin',
);

// Arduino — firmware chosen with the file picker (no uri needed)
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.filepicker,
);
```

The method signature and the meaning of each parameter:

```59:65:lib/ota_package.dart
  Future<void> updateFirmware(
    BluetoothDevice device,
    UpdateType updateType,
    FirmwareType firmwareType, {
    String? uri,
    int mtuSize,
  });
```

| Parameter | Required? | Meaning |
| --- | --- | --- |
| `device` | Yes | The connected `BluetoothDevice`. |
| `updateType` | Yes | `UpdateType.espidf` or `UpdateType.arduino`. |
| `firmwareType` | Yes | Source of the binary: `assets`, `filepicker`, or `url`. |
| `uri` | All except `filepicker` | Asset path or URL of the `.bin`. |
| `mtuSize` | Optional (default `500`) | Bytes per BLE packet. 1–512 for ESP-IDF, 1–510 for Arduino (lower by 2 when CRC-16 is on). |
| `integrity` | Optional (default none) | Composable SHA-256 / CRC-16 features; enable only what firmware supports. |

### Step 8 — Handle setup/loading errors

Wrap the call in a `try/catch` to handle setup-time failures (these are thrown,
unlike mid-transfer BLE errors which arrive on the stream):

```dart
try {
  await otaPackage.updateFirmware(
    device,
    UpdateType.espidf,
    FirmwareType.url,
    uri: url,
  );
} on EmptyFirmwareException catch (e) {
  print(e.message); // empty file / empty download / nothing picked
} on FirmwareDownloadException catch (e) {
  print('Download failed (${e.statusCode}): ${e.message}');
} on OtaException catch (e) {
  print(e.message); // any other OTA error, e.g. invalid mtuSize
}
```

### Step 9 — Check the result (optional)

```dart
if (otaPackage.firmwareUpdate) {
  print('OTA update successful');
} else {
  print('OTA update failed');
}
```

### Cancelling an update

```dart
await otaPackage.cancelUpdate();
```

> **Important:** Cancelling only stops the app from sending data — it does **not**
> reset the OTA state machine on the ESP32. You **must disconnect and reconnect**
> (re-discovering services) before starting a new OTA on the same device.

### Releasing resources

The package disposes itself when an update reaches a terminal state, so you
normally don't need to do anything. To abandon an unfinished update (e.g. on app
shutdown):

```dart
await otaPackage.dispose();
```

---

## 4. Current package scoring

The package is published on **pub.dev** under the `sparkleo.io` publisher. The
following reflects the most recently analyzed published release (**0.1.15**),
which the `1.0.0` release builds on:

| Metric | Value |
| --- | --- |
| **Pub points** | **135 / 160** |
| **Likes** | 22 |
| **Downloads** | ~101 |
| **License** | BSD-3-Clause |
| **Platforms** | Android, iOS, Linux, macOS (Web & Windows not supported) |

### Pub points breakdown (135 / 160)

| Category | Score | Notes |
| --- | --- | --- |
| Follow Dart file conventions | 25 / 30 | Lost 5 points: `CHANGELOG.md` did not reference the current version. |
| Provide documentation | 20 / 20 | 62.5% of the public API has dartdoc comments; an example is included. |
| Platform support | 20 / 20 | Supports 4 of 6 platforms. |
| Pass static analysis | 40 / 50 | Lost 10 points: a lint/formatting issue (`List<int>` angle brackets in a doc comment interpreted as HTML). |
| Support up-to-date dependencies | 30 / 40 | Lost 10 points: outdated constraints on `file_picker` and `flutter_blue_plus`. |

### How 1.0.0 addresses the gaps

The `1.0.0` release directly targets the categories where points were lost:

- **CHANGELOG (+5 potential):** `CHANGELOG.md` now contains a full, dated `1.0.0`
  entry referencing the current version.
- **Dependencies (+10 potential):** `pubspec.yaml` upgrades to current major
  versions — `flutter_blue_plus: ^2.3.8`, `file_picker: ^11.0.2`,
  `http: ^1.2.0`, plus a new `logger: ^2.7.0`.
- **Static analysis (+10 potential):** `print` statements were replaced with
  structured logging and the API was cleaned up, reducing analysis findings.

> Note: pub.dev recomputes the score after a new version is analyzed, so the
> exact `1.0.0` figure will be confirmed once it is published and re-scored.

---

## 5. Changelog — what's new in 1.0.0

### Added

- Optional, composable firmware integrity (`FirmwareIntegrityConfig` /
  `IntegrityFeature`): SHA-256 before transfer, per-packet CRC-16 with NACK
  retransmission, and post-flash SHA-256 (ESP-IDF PostSHA uses `SET_HASH`
  `0x07`). Features combine independently so devices may support any subset
  (or none).
- Integrity exception types for hash and CRC failures.

`1.0.0` (2026-06-08) is a substantial release focused on **type safety, correct
chunking, resource management, and a cleaner API**.

### Added

- **Typed exception hierarchy** — `OtaException` (base),
  `EmptyFirmwareException`, and `FirmwareDownloadException` (carrying the HTTP
  `statusCode`) — so callers handle errors by type instead of matching raw
  strings.
- **Empty-download rejection** — an HTTP 200 with 0 bytes is now rejected before
  chunking.
- **Early-fail guard** — the update aborts when the firmware is empty *before*
  any BLE handshake/writes, so the device is never left mid-update with nothing
  to flash.
- **`dispose()` method** plus automatic self-disposal when the update reaches a
  terminal state.
- **Optional `mtuSize` parameter** on `updateFirmware`, honoured by both the
  ESP-IDF and Arduino paths.
- **`maxMtuSize` (512) and `arduinoHeaderSize` (2) constants** with up-front,
  protocol-aware validation — out-of-range values throw `OtaException` before any
  BLE write instead of failing mid-transfer.
- **Structured `logger`-based logging**, replacing `print`.

### Fixed

- **Arduino updates now use the caller-supplied `mtuSize`.** Previously it was
  ignored in favour of the device-negotiated MTU and hardcoded values (`200`,
  `400`), so the requested chunk size never reached the device.

### Changed

- **Enum-based API** — `UpdateType` and `FirmwareType` enums replace the old
  integer codes (`1`, `2`, `3`).
- Firmware loaders now throw the typed exceptions instead of plain `String`s,
  and rethrow existing `OtaException`s without re-wrapping.
- Failure log message generalised from "BLE error" to "OTA update aborted" to
  reflect that it also covers validation failures.
- Example app: iOS deployment target raised to 13.0, Bluetooth usage
  descriptions added to `Info.plist`, and improved runtime permission handling
  and OTA error logging.

### Documentation

- Added a **"Platform setup"** section to the README covering the required iOS
  and Android BLE configuration.

### Removed

- Unused `service`/UUID parameters from `updateFirmware`.
- Unused helpers (`getFirmware`, `uint8ListToIntList`) from `Esp32OtaPackage`.
- The hardcoded `mtu` field (`400`); `sendPart` now takes the chunk size as a
  parameter sourced from `mtuSize`.

### Why these improvements matter

| Before 1.0.0 | After 1.0.0 |
| --- | --- |
| Integer codes (`1`, `2`, `3`) for update/firmware type — easy to misuse. | Self-documenting `UpdateType` / `FirmwareType` enums. |
| Errors thrown as raw `String`s. | Catchable, typed `OtaException` hierarchy with status codes. |
| Arduino ignored the requested chunk size. | `mtuSize` honoured by both protocols, validated up front. |
| BLE failures could crash the app. | Reported on the stream as `failedValue`; app stays alive. |
| Empty firmware could leave the device mid-update. | Early-fail guard aborts before any write. |
| Manual cleanup required. | Self-disposing + explicit `dispose()`. |
| `print`-based logging shipped to production. | Structured `logger`, suppressed in release builds. |

---

## 6. Future plan

Planned directions to keep raising both the capability and the pub.dev score:

### Reliability & protocol

- **Automatic recovery after cancel/disconnect** — manage the disconnect →
  reconnect → re-discover cycle internally so a fresh OTA can start without the
  caller manually rebuilding the connection.
- **Retry & resume** — where the device firmware supports it, resume an
  interrupted transfer instead of restarting from zero (per-packet CRC NACK
  retransmission is already available via `IntegrityFeature.packetCrc16`).
- ~~**Firmware integrity checks**~~ — shipped in 1.0.0 as optional SHA-256 /
  CRC-16 features.

### API & developer experience

- **Richer progress events** — a structured progress/state object (bytes sent,
  total bytes, current phase) alongside the simple percentage.
- **Helper for characteristic discovery** — a utility to locate the OTA service
  and notify/write characteristics, reducing the boilerplate currently shown in
  the example.
- **Higher test coverage** — unit tests over the chunking, validation, and
  protocol state machine using mocked BLE characteristics.

### Ecosystem & scoring

- **Keep dependencies current** — track `flutter_blue_plus`, `file_picker`, and
  `http` major releases to retain the up-to-date-dependencies points.
- **Close the remaining static-analysis gap** — eliminate the documentation/lint
  finding to recover the last analysis points.
- **Broaden platform support** — evaluate options for Web/Windows where the
  underlying BLE and file-picker stacks allow.
- **Expand documentation** — more end-to-end recipes (ESP-IDF vs Arduino
  firmware setup) and troubleshooting guidance for common GATT errors.

---

*Generated for `flutter_ota` v1.0.0.*
