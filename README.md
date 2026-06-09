**flutter_ota**

This package provides functionalities for Over-The-Air (OTA) updates for ESP32 devices using Flutter applications.

**Features**

* Supports firmware updates from bundled assets, a file picker, and URLs.
* Implements a progress stream to track update progress.
* Compatible with both ESP-IDF and Arduino firmware.
* Handles communication with ESP32 devices using Bluetooth Low Energy (BLE).
* Typed errors (`OtaException` and friends) and early validation of empty
  firmware, so failures surface clearly instead of corrupting an update.
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

5. Call `updateFirmware` with only the parameters that apply to your chosen
   `updateType` and `firmwareType` (passing unrelated parameters throws
   `ArgumentError`):

```dart
// ESP-IDF — firmware from assets
await otaPackage.updateFirmware(
  device,
  UpdateType.espidf,
  FirmwareType.assets,
  binFilePath: 'assets/firmware.bin',
  chunkSize: 500, // optional, ESP-IDF only (default 500)
);

// Arduino — firmware from URL
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.url,
  url: 'https://example.com/firmware.ino.bin',
  packetSize: 400, // optional, Arduino only (default 400)
  partSize: 16000, // optional, Arduino only (default 16000)
);

// Arduino — firmware from file picker (no extra params needed)
await otaPackage.updateFirmware(
  device,
  UpdateType.arduino,
  FirmwareType.filepicker,
);
```

| Parameter | Applies to |
| --- | --- |
| `binFilePath` | `FirmwareType.assets` only (required) |
| `url` | `FirmwareType.url` only (required) |
| `mtuSize` | `UpdateType.espidf` only (default `500`) |
| `packetSize` | `UpdateType.arduino` only (default `400`) |
| `partSize` | `UpdateType.arduino` only (default `16000`) |

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
    url: url,
    mtuSize: 500,
  );
} on EmptyFirmwareException catch (e) {
  // Firmware source was empty (no bytes to flash).
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
