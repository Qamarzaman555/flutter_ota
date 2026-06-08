// ignore_for_file: annotate_overrides, prefer_const_constructors

// Import necessary libraries
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

/// Shared logger for the OTA package.
///
/// Uses [PrettyPrinter] to emit colorized, level-tagged logs (with emojis) so
/// the BLE/OTA flow is easy to follow during development. In release builds the
/// default [DevelopmentFilter] suppresses output, so these logs do not ship to
/// production.
final Logger _logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 6,
    lineLength: 90,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
  ),
);

/// The type of update protocol used to flash the firmware.
///
/// * [UpdateType.espidf]: Firmware update following the ESP-IDF/Espressif
///   framework (formerly represented by the integer `1`).
/// * [UpdateType.arduino]: Firmware update based on the Arduino framework for
///   ESP32 (formerly represented by the integer `2`).
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

// Abstract class defining the structure of an OTA package
abstract class OtaPackage {
  /// Method to update firmware.
  ///
  /// [device]: The Bluetooth device to update firmware on.
  /// [updateType]: The type of update operation.
  /// [firmwareType]: The type of firmware to update.
  /// [binFilePath]: The file path of the firmware binary (optional).
  /// [url]: The URL to fetch firmware from (optional).
  /// [mtuSize]: The chunk size (in bytes) used to split the firmware into
  ///   packets sent to the device (optional).
  Future<void> updateFirmware(
    BluetoothDevice device,
    UpdateType updateType,
    FirmwareType firmwareType, {
    String? binFilePath,
    String? url,
    int mtuSize,
  });

  /// Property to track firmware update status
  bool firmwareUpdate = false;

  /// Stream to provide progress percentage.
  ///
  /// When an update is cancelled via [cancelUpdate], a value of [cancelledValue]
  /// (`-1`) is emitted so listeners can react to the cancellation. If the update
  /// fails because of a BLE error (e.g. the device disconnects mid-transfer or a
  /// write fails with a GATT error), [failedValue] (`-2`) is emitted instead of
  /// throwing, so the caller can update the UI without the app crashing.
  Stream<int> get percentageStream;

  /// Whether an OTA update is currently in progress.
  bool get isUpdating;

  /// Requests cancellation of an in-progress OTA update.
  ///
  /// This stops sending further firmware data and tears down any active
  /// notification subscription. It is safe to call even when no update is
  /// running. After cancelling, [cancelledValue] is emitted on
  /// [percentageStream].
  ///
  /// IMPORTANT: Cancelling only stops the app from sending data; it does NOT
  /// reset the OTA state machine on the ESP32, which is left mid-update. The
  /// caller MUST disconnect and reconnect (re-discovering services) before
  /// starting a new OTA on the same device. Starting another OTA on the same
  /// connection leaves the two sides out of sync and typically results in a BLE
  /// disconnect / GATT error.
  Future<void> cancelUpdate();

  /// Releases resources held by this instance.
  ///
  /// Cancels any active notification subscription and closes
  /// [percentageStream]. The package already disposes itself automatically when
  /// an update reaches a terminal state (success, failure, or cancellation), so
  /// you normally do NOT need to call this. Use it only to abandon an update
  /// that has not finished (e.g. on app shutdown). The instance must not be
  /// used after disposing.
  Future<void> dispose();
}

/// Value emitted on [OtaPackage.percentageStream] when an update is cancelled.
const int cancelledValue = -1;

/// Value emitted on [OtaPackage.percentageStream] when an update fails because
/// of a BLE error (e.g. the device disconnects or a write fails with a GATT
/// error). The package emits this instead of throwing so the app does not crash.
const int failedValue = -2;

/// A class responsible for handling BLE repository operations.
class BleRepository {
  // Write data to a Bluetooth characteristic
  Future<void> writeDataCharacteristic(
    BluetoothCharacteristic characteristic,
    Uint8List data,
  ) async {
    await characteristic.write(data);
  }

  /// Read data from a Bluetooth characteristic
  Future<List<int>> readCharacteristic(
    BluetoothCharacteristic characteristic,
  ) async {
    return await characteristic.read();
  }

  /// Request a specific MTU size from a Bluetooth device
  Future<void> requestMtu(BluetoothDevice device, int mtuSize) async {
    await device.requestMtu(mtuSize);
  }
}

/// Implementation of OTA package for ESP32
class Esp32OtaPackage implements OtaPackage {
  /// Properties
  int mtu = 400; // Maximum Transmission Unit size
  int part = 16000; // Part size for firmware update
  final BluetoothCharacteristic
  notifyCharacteristic; // Characteristic for notifications
  final BluetoothCharacteristic
  writeCharacteristic; //Characteristic for writing data
  StreamSubscription?
  subscription; // declare subscription as an instance variable
  bool firmwareUpdate = false; // Flag indicating firmware update status

  bool _cancelRequested = false; // Flag indicating a cancellation was requested
  bool _isUpdating = false; // Flag indicating an update is currently running

  final StreamController<int> _percentageController =
      StreamController<int>.broadcast();

  @override
  Stream<int> get percentageStream => _percentageController.stream; // Getter for percentage update stream

  @override
  bool get isUpdating => _isUpdating;

  /// Constructor
  Esp32OtaPackage(this.notifyCharacteristic, this.writeCharacteristic);

  /// Requests cancellation of an in-progress OTA update.
  @override
  Future<void> cancelUpdate() async {
    if (!_isUpdating) return;
    _logger.w('OTA update cancellation requested');
    _cancelRequested = true;
    await subscription?.cancel();
    subscription = null;
    _completeUpdate(cancelledValue);
  }

  /// Releases resources held by this instance.
  ///
  /// In normal operation the package disposes itself when the update reaches a
  /// terminal state (success, failure, or cancellation), so calling this is
  /// only needed to abandon an update that has not finished (e.g. the app is
  /// shutting down). Safe to call more than once.
  @override
  Future<void> dispose() async {
    await subscription?.cancel();
    subscription = null;
    if (!_percentageController.isClosed) {
      await _percentageController.close();
    }
  }

  /// Emits [value] on [percentageStream], guarding against a closed controller.
  ///
  /// Notification callbacks can fire after [dispose] has closed the controller;
  /// adding to a closed controller would throw, so we silently drop late
  /// emissions instead.
  void _emitPercentage(int value) {
    if (_percentageController.isClosed) return;
    _percentageController.add(value);
  }

  /// Emits a terminal [value] and then releases all resources.
  ///
  /// Called whenever the update reaches a terminal state — success, failure, or
  /// cancellation — so the package cleans up after itself: it cancels the BLE
  /// notification subscription and closes [percentageStream]. This makes the
  /// package leak-safe on its own, with no dependency on a widget/page
  /// lifecycle (the caller can navigate freely while the update runs). Safe to
  /// call more than once; later calls are ignored once the stream is closed.
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

  /// Centralised cleanup for a failed/interrupted OTA.
  ///
  /// BLE errors (device disconnect, GATT 133, etc.) are reported on
  /// [percentageStream] instead of being thrown, so a mid-transfer failure does
  /// not surface as an unhandled exception and crash the app. If the failure was
  /// caused by a user cancellation, [cancelledValue] is emitted; otherwise
  /// [failedValue] is emitted.
  void _handleUpdateError(Object error) {
    _logger.e('OTA update aborted due to BLE error', error: error);
    firmwareUpdate = false;
    _completeUpdate(_cancelRequested ? cancelledValue : failedValue);
  }

  /// Function to read binary firmware file and split it into chunks
  Future<List<Uint8List>> _readBinaryFile(String filePath, int mtuSize) async {
    _logger.d('Reading binary firmware from asset path: $filePath');
    ByteData fileData = await rootBundle.load(filePath);
    List<int> bytes = fileData.buffer.asUint8List();
    _logger.t('Firmware bytes: ${Uint8List.fromList(bytes)}');
    List<Uint8List> firmwareData = [];
    // Split file data into chunks based on MTU size
    for (int i = 0; i < bytes.length; i += mtuSize) {
      int end = i + mtuSize;
      if (end > bytes.length) {
        end = bytes.length;
      }
      firmwareData.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return firmwareData; // Return firmware data chunks
  }

  /// Convert `Uint8List` to `List<int>`
  List<int> uint8ListToIntList(Uint8List uint8List) {
    return uint8List.toList();
  }

  /// Get firmware based on firmwareType
  Future<List<Uint8List>> getFirmware(
    FirmwareType firmwareType,
    int mtuSize, {
    String? binFilePath,
  }) {
    if (firmwareType == FirmwareType.filepicker) {
      _logger.d('Chunk size (MTU) for firmware: $mtuSize');
      return _getFirmwareFromPicker(mtuSize - 3);
    } else if (firmwareType == FirmwareType.assets && binFilePath != null) {
      return _readBinaryFile(binFilePath, mtuSize);
    } else {
      return Future.value([]); // Return empty list for other cases
    }
  }

  /// Get firmware chunks from file picker
  Future<List<Uint8List>> _getFirmwareFromPicker(int mtuSize) async {
    _logger.d('Chunk size (MTU) in file picker: $mtuSize');

    final result = await FilePicker.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      _logger.w('No firmware file selected');
      return []; // Return an empty list when no file is picked
    }

    final file = result.files.first;
    _logger.d('Selected firmware file: ${file.name}');
    try {
      final firmwareData = await _openFileAndGetFirmwareData(file, mtuSize);

      if (firmwareData.isEmpty) {
        throw 'Empty firmware data. Please select a valid firmware file.';
      }

      return firmwareData;
    } catch (e) {
      throw 'Error getting firmware data: $e';
    }
  }

  /// Get firmware chunks from file picker
  Future<Uint8List> _getFirmwareFromPickerArduino(int mtuSize) async {
    _logger.d('Chunk size (MTU) in file picker (Arduino): $mtuSize');
    final Uint8List binfiledata;

    final result = await FilePicker.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      _logger.w('No firmware file selected');
      return Uint8List(0); // Return an empty list when no file is picked
    }

    final file = result.files.first;
    _logger.d('Selected firmware file: ${file.name}');
    try {
      final bytes = await File(file.path!).readAsBytes();
      binfiledata = Uint8List.fromList(bytes);

      return binfiledata;
    } catch (e) {
      throw 'Error getting firmware data: $e';
    }
  }

  Future<List<Uint8List>> _getFirmwareFromUrl(String url, int mtuSize) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(Duration(seconds: 10));

      /// Check if the HTTP request was successful (status code 200)
      if (response.statusCode == 200) {
        final List<int> bytes = response.bodyBytes;

        final int chunkSize = mtuSize;
        List<Uint8List> chunks = [];
        for (int i = 0; i < bytes.length; i += chunkSize) {
          int end = i + chunkSize;
          if (end > bytes.length) {
            end = bytes.length;
          }
          Uint8List chunk = Uint8List.fromList(bytes.sublist(i, end));
          chunks.add(chunk);
        }
        return chunks;
      } else {
        /// Handle HTTP error (e.g., status code is not 200)
        throw 'HTTP Error: ${response.statusCode} - ${response.reasonPhrase}';
      }
    } catch (e) {
      /// Handle other errors (e.g., timeout, network connectivity issues)
      throw 'Error fetching firmware from URL: $e';
    }
  }

  Future<Uint8List> _getFirmwareFromUrlArduino(String url, int mtuSize) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(Duration(seconds: 10));

      /// Check if the HTTP request was successful (status code 200)
      if (response.statusCode == 200) {
        final List<int> bytes = response.bodyBytes;
        final int chunkSize = mtuSize - 3;
        Uint8List firmware = Uint8List(0); // Initialize an empty Uint8List
        for (int i = 0; i < bytes.length; i += chunkSize) {
          int end = i + chunkSize;
          if (end > bytes.length) {
            end = bytes.length;
          }
          Uint8List chunk = Uint8List.fromList(bytes.sublist(i, end));
          firmware = Uint8List.fromList([
            ...firmware,
            ...chunk,
          ]); // Concatenate the chunks
        }
        return firmware;
      } else {
        /// Handle HTTP error (e.g., status code is not 200)
        throw 'HTTP Error: ${response.statusCode} - ${response.reasonPhrase}';
      }
    } catch (e) {
      /// Handle other errors (e.g., timeout, network connectivity issues)
      throw 'Error fetching firmware from URL: $e';
    }
  }

  /// Open file, read bytes, and split into chunks
  Future<List<Uint8List>> _openFileAndGetFirmwareData(
    PlatformFile file,
    int mtuSize,
  ) async {
    final bytes = await File(file.path!).readAsBytes();
    List<Uint8List> firmwareData = [];
    _logger.d('Dividing firmware data into chunks');
    for (int i = 0; i < bytes.length; i += mtuSize) {
      int end = i + mtuSize;
      if (end > bytes.length) {
        end = bytes.length;
      }
      firmwareData.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return firmwareData;
  }

  /// sendPart function which is used to send parts to the esp32
  Future<void> sendPart(int position, Uint8List data) async {
    if (_cancelRequested) {
      _logger.w('sendPart aborted due to cancellation');
      return;
    }
    final bleRepo = BleRepository();
    int start = (position * part);
    int end = (position + 1) * part;
    if (data.length < end) {
      end = data.length;
    }
    int parts = (end - start) ~/ mtu;
    _logger.d('Parts to send: $parts');
    for (int i = 0; i < parts; i++) {
      _logger.t('Created part $i');
      Uint8List toSend = Uint8List(mtu + 2);
      toSend[0] = 0XFB;
      toSend[1] = i;
      int variable = 2;
      for (int y = 0; y < mtu; y++) {
        /// toSend.append(data[(position * PART) + (MTU * i) + y])

        int x = data[(position * part) + (mtu * i) + y];
        Uint8List list2 = Uint8List.fromList([x]);

        /// Copy the contents of list1 into the beginning of combinedList
        toSend.setRange(variable, variable + list2.length, list2);
        variable = variable + list2.length;
      }

      /// print statement below should be replaced with actual sending code

      _logger.t('Writing data, payload length is ${toSend.length}');
      await bleRepo.writeDataCharacteristic(writeCharacteristic, toSend);
    }
    if ((end - start) % mtu != 0) {
      _logger.t('Writing remainder part');
      int rem = (end - start) % mtu;
      Uint8List toSend = Uint8List(rem + 2);
      toSend[0] = 0XFB;
      toSend[1] = parts;
      int variable = 2;
      for (int y = 0; y < rem; y++) {
        int x = data[(position * part) + (mtu * parts) + y];
        Uint8List list2 = Uint8List.fromList([x]);

        /// Copy the contents of list1 into the beginning of combinedList
        toSend.setRange(variable, variable + list2.length, list2);
        variable = variable + list2.length;
      }

      _logger.t('Writing remainder payload');
      await bleRepo.writeDataCharacteristic(writeCharacteristic, toSend);
    }

    Uint8List update = Uint8List.fromList([
      0xFC,
      ((end - start) ~/ 256),
      ((end - start) % 256),
      (position ~/ 256),
      (position % 256),
    ]);

    await bleRepo.writeDataCharacteristic(writeCharacteristic, update);
    _logger.t('Sent part update marker: $update');
  }

  /// sendPArt function ends here

  @override
  Future<void> updateFirmware(
    BluetoothDevice device,
    UpdateType updateType,
    FirmwareType firmwareType, {
    String? binFilePath,
    String? url,
    int mtuSize = 500,
  }) async {
    _cancelRequested = false;
    _isUpdating = true;
    try {
      if (updateType == UpdateType.espidf) {
        final bleRepo = BleRepository();

        /// Chunk size used to split the firmware into packets (defaults to 500).
        _logger.i('Starting ESP-IDF OTA — chunk size (MTU): $mtuSize');

        /// Prepare a byte list to write MTU size to controlCharacteristic
        Uint8List byteList = Uint8List(2);
        byteList[0] = mtuSize & 0xFF;
        byteList[1] = (mtuSize >> 8) & 0xFF;

        List<Uint8List> binaryChunks;

        /// Choose firmware source based on firmwareType
        if (firmwareType == FirmwareType.assets &&
            binFilePath != null &&
            binFilePath.isNotEmpty) {
          binaryChunks = await _readBinaryFile(binFilePath, mtuSize);
        } else if (firmwareType == FirmwareType.filepicker) {
          binaryChunks = await _getFirmwareFromPicker(mtuSize);
        } else if (firmwareType == FirmwareType.url &&
            url != null &&
            url.isNotEmpty) {
          binaryChunks = await _getFirmwareFromUrl(url, mtuSize);
        } else {
          binaryChunks = [];
        }

        /// Write x01 to the controlCharacteristic and check if it returns value of 0x02
        await bleRepo.writeDataCharacteristic(writeCharacteristic, byteList);
        await bleRepo.writeDataCharacteristic(
          notifyCharacteristic,
          Uint8List.fromList([1]),
        );

        /// Read value from controlCharacteristic
        List<int> value = await bleRepo
            .readCharacteristic(notifyCharacteristic)
            .timeout(Duration(seconds: 10));
        _logger.d('Control characteristic returned: ${value[0]}');

        int packageNumber = 0;
        _logger.i('Sending ${binaryChunks.length} firmware chunks');
        for (Uint8List chunk in binaryChunks) {
          /// Abort sending if a cancellation was requested
          if (_cancelRequested) {
            _logger.w('OTA update cancelled while sending firmware');
            firmwareUpdate = false;
            _completeUpdate(cancelledValue);
            return;
          }

          /// Write firmware chunks to dataCharacteristic
          await bleRepo.writeDataCharacteristic(writeCharacteristic, chunk);
          packageNumber++;

          double progress = (packageNumber / binaryChunks.length) * 100;
          int roundedProgress = progress.round(); // Rounded off progress value
          _logger.d(
            'Writing package $packageNumber/${binaryChunks.length} — $roundedProgress%',
          );
          _emitPercentage(roundedProgress);
        }

        /// Write x04 to the controlCharacteristic to finish the update process
        await bleRepo.writeDataCharacteristic(
          notifyCharacteristic,
          Uint8List.fromList([4]),
        );

        /// Check if controlCharacteristic reads 0x05, indicating OTA update finished
        value = await bleRepo
            .readCharacteristic(notifyCharacteristic)
            .timeout(Duration(seconds: 600));
        _logger.d('Control characteristic returned: ${value[0]}');

        if (value[0] == 5) {
          _logger.i('OTA update finished successfully');
          firmwareUpdate = true; // Firmware update was successful
          // All packets transferred and acknowledged: emit 100% and dispose.
          _completeUpdate(100);
        } else {
          _logger.e('OTA update failed (unexpected status ${value[0]})');
          firmwareUpdate = false; // Firmware update failed
          _completeUpdate(failedValue);
        }
      } else if (updateType == UpdateType.arduino) {
        final bleRepo = BleRepository();

        /// Get MTU size from the device
        int mtuSize = await device.mtu.first;

        _logger.i('Starting Arduino OTA — device MTU: $mtuSize');

        /// Prepare a byte list to write MTU size to controlCharacteristic
        Uint8List byteList = Uint8List(2);
        byteList[0] = 200 & 0xFF;
        byteList[1] = (200 >> 8) & 0xFF;
        Uint8List? binFile;

        /// Choose firmware source based on firmwareType
        if (firmwareType == FirmwareType.assets && binFilePath != null) {
          ByteData fileData = await rootBundle.load(binFilePath);
          List<int> bytes = fileData.buffer.asUint8List();
          binFile = Uint8List.fromList(bytes);
          _logger.t('Bin file after conversion: $binFile');
          _logger.d('Bin file length: ${binFile.length}');
        } else if (firmwareType == FirmwareType.filepicker) {
          binFile = await _getFirmwareFromPickerArduino(200);
          _logger.t('Bin file: $binFile');
        } else if (firmwareType == FirmwareType.url &&
            url != null &&
            url.isNotEmpty) {
          binFile = await _getFirmwareFromUrlArduino(url, mtuSize);
        } else {
          binFile = Uint8List(0);
        }
        int fileLen = binFile.length;
        int fileParts = (fileLen / part).ceil();
        _logger.d('Firmware length: $fileLen bytes, file parts: $fileParts');

        ///1. Start stream which listens to the notification advertisement
        await notifyCharacteristic.setNotifyValue(true);
        subscription = notifyCharacteristic.onValueReceived.listen((
          value,
        ) async {
          /// Stop reacting to notifications once a cancellation is requested
          if (_cancelRequested) {
            _logger.w('OTA update cancelled while sending firmware');
            firmwareUpdate = false;
            _completeUpdate(cancelledValue);
            return;
          }

          try {
            _logger.t('Received notification value: $value');
            double progress = (value[2] / fileParts) * 100;
            int roundedProgress = progress.round();

            /// Rounded off progress value
            _logger.d(
              'Writing part ${value[2]}/$fileParts — $roundedProgress%',
            );
            _emitPercentage(roundedProgress);
            if (value[0] == 0xF1)
            /// this basically is checking listener stream
            {
              Uint8List bytes = Uint8List.fromList([value[1], value[2]]);
              ByteData byteData = ByteData.sublistView(bytes);
              int nxt = byteData.getUint16(0);

              /// Used getUint16 for a 2-byte integer
              _logger.d('Next part requested: $nxt');
              await sendPart(nxt, binFile!);
            }
            if (value[0] == 0x0F) {
              _logger.i('OTA update complete');
              firmwareUpdate = true;
              // Final part acknowledged: emit 100% and dispose.
              _completeUpdate(100);
            }
            if (value[0] == 0xF2) {
              _logger.i('New bin file installation begins on ESP32');
            }
          } catch (e) {
            // Writes triggered from the notification listener run after
            // updateFirmware has returned, so guard them here too.
            _handleUpdateError(e);
          }
        });

        ///2. Send 0xFD first to start reading
        Uint8List byteListData = Uint8List(1);
        byteList[0] = 0xFD;
        await bleRepo.writeDataCharacteristic(
          writeCharacteristic,
          byteListData,
        );

        ///3. Send 0xFE appended with other info
        ///--------> 2nd step create and then send file size
        Uint8List fileSize = Uint8List(5);
        fileSize[0] = 0xFE; // The fixed byte
        fileSize[1] =
            (fileLen >> 24) & 0xFF; // Most significant byte of fileLen
        fileSize[2] = (fileLen >> 16) & 0xFF; // Second most significant byte
        fileSize[3] = (fileLen >> 8) & 0xFF; // Third most significant byte
        fileSize[4] = fileLen & 0xFF; // Least significant byte
        _logger.d('Sending file size packet: $fileSize');
        await bleRepo.writeDataCharacteristic(writeCharacteristic, fileSize);

        ///4. Send 0xFF appended with other info - see code below
        ///--------> 3rd step create and then send otaInfo
        Uint8List otaInfo = Uint8List(5);
        otaInfo[0] = 0xFF;
        otaInfo[1] = (fileParts ~/ 256);
        otaInfo[2] = (fileParts % 256);
        otaInfo[3] = (mtu ~/ 256);
        otaInfo[4] = (mtu % 256);
        _logger.d('Sending OTA info packet: $otaInfo');
        await bleRepo.writeDataCharacteristic(writeCharacteristic, otaInfo);

        ///5. Divide bin file into parts
        int packageNumber = 0;
        sendPart(0, binFile);
        double progress = (packageNumber / fileParts) * 100;
        int roundedProgress = progress.round(); // Rounded off progress value
        _logger.d('Writing part $packageNumber/$fileParts — $roundedProgress%');
        _emitPercentage(roundedProgress);
      }
    } catch (e) {
      // A BLE error (disconnect, GATT 133, etc.) must not crash the app: report
      // it on the stream and clean up instead of letting it propagate.
      _handleUpdateError(e);
    }
  }
}
