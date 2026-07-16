**flutter_ota**

This package provides functionalities for Over-The-Air (OTA) updates for ESP32 devices using Flutter applications.

**Features**

* Supports firmware updates from bundled assets, a file picker, and URLs.
* Implements a progress stream to track update progress.
* Compatible with both ESP-IDF and Arduino firmware.
* Handles communication with ESP32 devices using Bluetooth Low Energy (BLE).
* Typed errors (`OtaException` and friends) and early validation of empty
  firmware, so failures surface clearly instead of corrupting an update.
* Optional firmware integrity: SHA-256 before transfer and post-flash SHA-256
  — enable any combination your device supports (or none).
* Self-disposing: resources are released automatically when an update reaches a
  terminal state.

**Requirements**

* Flutter `>=3.32.0`
* Dart `>=3.8.0 <4.0.0`

**Installation**

1. Add the following line to your `pubspec.yaml` file:

```yaml
dependencies:
  flutter_ota: ^1.0.0
```

2. Run the following command to install the package:

```bash
flutter pub get
```

**Platform setup**

Because the package communicates over Bluetooth Low Energy, each platform needs
the appropriate permissions and a minimum OS version configured before an update
will run.

### iOS

* Set the iOS deployment target to **13.0** or higher (required by
  `flutter_blue_plus`). In `ios/Podfile`:

```ruby
platform :ios, '13.0'
```

* Add the Bluetooth usage descriptions to `ios/Runner/Info.plist` so the system
  permission prompt has a reason to show the user:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to and update the firmware of nearby ESP32 devices.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses Bluetooth to connect to and update the firmware of nearby ESP32 devices.</string>
```

### Android

Add the BLE permissions to `android/app/src/main/AndroidManifest.xml`. The
`BLUETOOTH`/`BLUETOOTH_ADMIN` permissions cover Android 11 and below, while
`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` cover Android 12 (API 31) and above:

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

Request the runtime permissions (Bluetooth and, on older Android versions,
location) before starting an update. See the example app for a complete
permission-handling flow.

**Usage**

1. Import the necessary libraries:

```dart
import 'package:flutter_ota/ota_package.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
```

2. Connect to the ESP32 device using the `flutter_blue_plus` package.

3. Create an instance of the `Esp32OtaPackage` class, providing the required characteristics:

```dart
// Replace with the actual UUIDs of your ESP32 BLE service and characteristics
BluetoothService service = ...;
BluetoothCharacteristic writeCharacteristic = ...;
BluetoothCharacteristic notifyCharacteristic = ...;

// Constructor order is (notifyCharacteristic, writeCharacteristic).
Esp32OtaPackage otaPackage = Esp32OtaPackage(notifyCharacteristic, writeCharacteristic);
```

4. Choose the firmware update type (`updateType`) and firmware type (`firmwareType`):

* `updateType` (`UpdateType` enum):
    * `UpdateType.espidf`: ESP-IDF/Espressif Firmware Update
      Indicates that the firmware update follows the ESP-IDF/Espressif framework. In this case, you'll typically perform OTA updates using binary files and utilize the NimBLE Bluetooth stack.

    * `UpdateType.arduino`: Arduino IDE-Based Firmware Update
      Suggests that the firmware update is based on the Arduino framework for ESP32. This could involve custom OTA update logic implemented on the ESP32 side, possibly using specific GATT services and characteristics for communication.
      By checking the updateType parameter, you can adapt your OTA update logic to the specific requirements of the firmware implementation. This ensures compatibility and seamless OTA updates for different types of ESP32 firmware.
* `firmwareType` (`FirmwareType` enum):
    * `FirmwareType.assets`: For binary firmware files stored in your Flutter project assets.
    * `FirmwareType.filepicker`: To select a binary firmware file from the device storage.
    * `FirmwareType.url`: For downloading firmware from a URL.

5. Call `updateFirmware` with the parameters that apply to your chosen
   `firmwareType` (`uri` is required for every type except
   `FirmwareType.filepicker`):

```dart
// ESP-IDF — firmware from assets
await otaPackage.updateFirmware(
  device,
  UpdateType.espidf,
  FirmwareType.assets,
  uri: 'assets/firmware.bin',
  mtuSize: 500, // optional (default 500)
);

// Arduino — firmware from URL
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.url,
  uri: 'https://example.com/firmware.ino.bin',
  mtuSize: 500, // optional (default 500)
);

// Arduino — firmware from file picker (no uri needed)
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.filepicker,
);

// Optional integrity — enable only what your firmware supports:
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.url,
  uri: 'https://example.com/firmware.bin',
  integrity: FirmwareIntegrityConfig(
    features: {
      IntegrityFeature.shaBeforeTransfer, // app vs server hash
      IntegrityFeature.shaAfterFlash,     // device verifies flash, then reboot
    },
    expectedSha256Hex: serverProvidedSha256Hex, // 64 hex chars
  ),
);
```

| Parameter | Applies to |
| --- | --- |
| `uri` | Required for every `FirmwareType` except `FirmwareType.filepicker` |
| `mtuSize` | Both update types (default `500`); see [Chunk size and BLE MTU](#chunk-size-mtusize-and-ble-mtu-negotiation) below |
| `integrity` | Optional; defaults to no integrity checks. See [Firmware integrity](#firmware-integrity-optional) |

### Chunk size (`mtuSize`) and BLE MTU negotiation

`mtuSize` is the number of **firmware payload bytes** per BLE transfer unit. It is
**not** the same as the ATT MTU negotiated by
`BluetoothDevice.requestMtu()` — the package does **not** call `requestMtu()`
for you. Your app must negotiate BLE MTU before starting an update, and the
`mtuSize` you pass to `updateFirmware` must fit within what was actually
negotiated.

| Protocol | How `mtuSize` is used |
| --- | --- |
| **ESP-IDF** | Splits firmware into chunks at load time (assets, file picker, URL); sends the value to the device in the handshake MTU packet; each chunk written must be ≤ `mtuSize`. |
| **Arduino** | Loads the full binary for file picker (chunk size is not used at load time); splits each 16 KB segment into `0xFB` BLE packets of `mtuSize` bytes during transfer; sends the value to the device in the `0xFF` handshake packet. |

**Aligning `requestMtu()` with `mtuSize`:**

* **ESP-IDF:** each characteristic write is one firmware chunk, so `mtuSize`
  must fit the negotiated ATT MTU (hard cap 512).
* **Arduino:** each write is `mtuSize + 2` bytes on the wire (2-byte `0xFB`
  header), so ensure the wire size fits within the negotiated ATT MTU.

```dart
// Arduino example: request enough ATT MTU for payload + 2-byte header.
await device.requestMtu(512);

await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.filepicker,
  mtuSize: 510, // 510 + 2 = 512 on the wire
);
```

If `requestMtu()` and `mtuSize` are misaligned (for example, negotiating `500`
but passing `mtuSize: 509` for Arduino), up-front validation may still pass
while GATT writes fail at runtime.

`mtuSize` is validated before any data is sent and must be:

* **`UpdateType.espidf`:** between `1` and `512` (`maxMtuSize`).
* **`UpdateType.arduino`:** between `1` and `510` (`maxMtuSize - arduinoHeaderSize`).
  The Arduino protocol prepends a 2-byte header to every packet.

An out-of-range value throws an `OtaException` before any BLE writes begin.

### Firmware integrity (optional)

Integrity is **off by default** so existing firmware keeps working. Features are
independent — combine any subset your device supports:

| Feature | Where it runs | Device support needed? |
| --- | --- | --- |
| `shaBeforeTransfer` | Flutter compares loaded bytes to `expectedSha256Hex` / `expectedSha256Bytes` before BLE | No |
| `shaAfterFlash` | App sends expected SHA-256; device verifies flash before success/reboot | Yes |

```dart
// SHA at start only (server hash, no device changes):
FirmwareIntegrityConfig(
  features: {IntegrityFeature.shaBeforeTransfer},
  expectedSha256Hex: '...', // 64 hex chars
)

// SHA after flash only:
FirmwareIntegrityConfig(
  features: {IntegrityFeature.shaAfterFlash},
  expectedSha256Hex: '...',
)
```

**ESP-IDF PostSHA:** after all image chunks, control `0x07` (`SET_HASH`) +
32-byte digest on data, read `0x02` ACK, then control `0x04` DONE. Do not use
control `0x02` for the hash — that opcode is device→phone ACK. Status `6` =
hash mismatch / failure. **Arduino:** `0xF9` flags, `0xFA` + 32-byte digest,
mismatch `0x0E`.

6. Listen to the `percentageStream` of the `otaPackage` to track the update progress:

```dart
StreamSubscription subscription = otaPackage.percentageStream.listen((progress) {
  print('OTA update progress: $progress%');
});

// ... (update your UI based on the progress)

await subscription.cancel();
```

7. Check the `firmwareUpdate` property of the `otaPackage` to determine if the update was successful:

```dart
if (otaPackage.firmwareUpdate) {
  print('OTA update successful');
} else {
  print('OTA update failed');
}
```

## Cancelling an update

Call `cancelUpdate()` to stop an in-progress OTA. When this happens, the package
emits `cancelledValue` (`-1`) on `percentageStream`. If the update instead fails
because of a BLE error (the device disconnects mid-transfer, a write fails with a
GATT 133 error, etc.), the package emits `failedValue` (`-2`) on
`percentageStream` rather than throwing, so the failure does not crash your app.

```dart
otaPackage.percentageStream.listen((progress) {
  if (progress == cancelledValue) {
    // Update was cancelled by the user.
  } else if (progress == failedValue) {
    // Update failed because of a BLE error.
  } else {
    // Normal progress (0-100).
  }
});
```

> **Important:** Cancelling only stops the app from sending data. It does **not**
> reset the OTA state machine on the ESP32, which is left mid-update. The caller
> **must disconnect and reconnect** (re-discovering services) before starting a
> new OTA on the same device. Starting another OTA on the same connection leaves
> the two sides out of sync and typically results in a BLE disconnect / GATT
> error. See the example app for how it disconnects after a cancel and prompts
> the user to reconnect.

## Error handling

The package distinguishes two kinds of failures:

* **BLE / transport errors during an in-progress update** (device disconnects, a
  write fails with a GATT error, etc.) are reported on `percentageStream` as
  `failedValue` (`-2`) rather than thrown, so a mid-transfer drop does not crash
  your app. Handle these via the stream as shown above.

* **Setup / firmware-loading errors** (e.g. an empty file, an empty download, or
  a non-200 HTTP response) are thrown as typed exceptions before the OTA writes
  begin, so the device is never left mid-update with nothing to flash. Wrap
  `updateFirmware` in a `try/catch` to handle them:

```dart
try {
  await otaPackage.updateFirmware(
    device,
    UpdateType.espidf,
    FirmwareType.url,
    uri: url,
    mtuSize: 500,
  );
} on EmptyFirmwareException catch (e) {
  // Firmware source was empty (no bytes to flash).
  print(e.message);
} on FirmwareHashMismatchException catch (e) {
  // Pre-transfer SHA-256 did not match the expected digest.
  print(e.message);
} on FirmwareDownloadException catch (e) {
  // HTTP download failed; e.statusCode is set for non-200 responses.
  print('Download failed (${e.statusCode}): ${e.message}');
} on OtaException catch (e) {
  // Any other OTA error.
  print(e.message);
}
```

The exception types are:

| Exception | When it is thrown |
| --- | --- |
| `OtaException` | Base class for all OTA errors thrown by the package. |
| `EmptyFirmwareException` | The firmware source yields no data (empty asset/file, empty download, or no file selected). |
| `FirmwareDownloadException` | The HTTP download fails (non-200 status, timeout, or network error). Carries an optional `statusCode`. |

## Releasing resources

The package disposes itself automatically once an update finishes, fails, or is
cancelled, so you normally do **not** need to do anything. To abandon an update
that has not finished (for example, on app shutdown), call `dispose()`:

```dart
await otaPackage.dispose();
```

## Example Application

The example application code is available in the example folder of this repository.

### ESP-IDF OTA Firmware

The article (https://michaelangerer.dev/esp32/ble/ota/2021/06/08/esp32-ota-part-2.html) provides insights into the core logic for executing an Over-The-Air (OTA) update using ESP-IDF framework. This firmware update method leverages the capabilities of ESP32 devices to wirelessly update their firmware via Bluetooth Low Energy (BLE).

### Arduino IDE OTA Firmware

The GitHub repository (https://github.com/fbiego/ESP32_BLE_OTA_Arduino) provides firmware suitable for integration utilizing the Arduino IDE framework.

## Conclusion

The `flutter_ota` package provides a streamlined approach to performing OTA firmware updates for ESP32 devices using Flutter applications. It simplifies communication with ESP32 devices over Bluetooth Low Energy (BLE) and streamlines the OTA update process. This package offers several key features:

* Support for various firmware update scenarios (binary files, URLs)
* Progress tracking through a stream for updating UI elements
* Compatibility with different firmware types
* Asynchronous programming for efficient BLE communication

By integrating `flutter_ota` into your Flutter project, you can seamlessly deliver firmware updates to your ESP32 devices wirelessly, enhancing user experience and ensuring your devices stay up-to-date.
This comprehensive explanation effectively covers the `flutter_ota` package, its functionalities, and its usage within a Flutter application for OTA updates on ESP32 devices. It provides valuable insights for developers seeking to implement wireless firmware updates in their projects. 
