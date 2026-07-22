# flutter_ota FAQ

Short answers to questions that come up when integrating or upgrading the
package. For a full walkthrough see [DOCUMENTATION.md](DOCUMENTATION.md); for
the `0.x` → `1.0.0` API break see [MIGRATION.md](MIGRATION.md).

## Which `UpdateType` should I use?

| Firmware on the ESP32 | Use |
| --- | --- |
| ESP-IDF / Espressif NimBLE OTA | `UpdateType.espidf` |
| Arduino BLE OTA (e.g. fbiego-style) | `UpdateType.arduino` |

The enums only select the **phone-side** protocol. Your device must expose the
matching GATT service and speak the matching opcodes. Sequence diagrams:
[DOCUMENTATION.md §4](DOCUMENTATION.md#4-protocol-handshake-sequences).

## Why did my call break after upgrading to 1.0.0?

`updateFirmware` no longer takes integer codes or the extra
`service` / characteristic positional arguments. Map `1`/`2`/`3` to
`UpdateType` / `FirmwareType` and pass a single `uri` where needed — see
[MIGRATION.md](MIGRATION.md).

## Do I need firmware integrity?

No. `FirmwareIntegrityConfig` defaults to none; the wire format is unchanged.
Turn on `shaBeforeTransfer` / `shaAfterFlash` only if your device firmware
implements those features.

## `mtuSize` vs `requestMtu()` — what's the difference?

- `BluetoothDevice.requestMtu()` negotiates the BLE ATT MTU (your app must call
  this; the package does not).
- `mtuSize` is how many **firmware payload bytes** the package puts in each
  write (default `500`).

For Arduino, each write is `mtuSize + 2` bytes on the wire (header). Keep
`mtuSize` within what the negotiated ATT MTU allows, and within protocol caps
(512 ESP-IDF / 510 Arduino).

## Progress stuck after cancel — can I start again immediately?

No. `cancelUpdate()` only stops the app from sending. The ESP32 OTA state
machine is usually left mid-update. **Disconnect, reconnect, and rediscover
services** before starting another OTA on that device.

## Progress shows `-1` or `-2` — is that an error code?

They are intentional stream sentinels:

| Value | Constant | Meaning |
| --- | --- | --- |
| `-1` | `cancelledValue` | Caller cancelled |
| `-2` | `failedValue` | BLE / transfer failure (emitted instead of crashing) |

Integrity mismatches (`FirmwareHashMismatchException`,
`DeviceHashMismatchException`) also emit `failedValue`, then rethrow so you can
catch them by type after `await updateFirmware(...)`.

## Which platforms are supported?

BLE OTA is aimed at **Android** and **iOS**. The package may analyze on other
desktop targets via dependencies, but real updates need a BLE stack and the
permissions described in the [README](README.md#platform-setup).

## Where is the example app?

[`example/`](example/README.md) — scan, connect, and flash with the Arduino
default UUIDs (replace them for your firmware).

## How do I contribute?

See [CONTRIBUTING.md](CONTRIBUTING.md).
