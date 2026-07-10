import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/firmware/firmware_loader.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_ota/src/models/firmware_type.dart';
import 'package:flutter_ota/src/models/ota_package.dart';
import 'package:flutter_ota/src/models/update_type.dart';
import 'package:flutter_ota/src/protocol/arduino_ota_protocol.dart';
import 'package:flutter_ota/src/protocol/espidf_ota_protocol.dart';
import 'package:flutter_ota/src/transport/ble_repository.dart';

/// ESP32 OTA client backed by the ESP-IDF and Arduino BLE protocols.
class Esp32OtaPackage implements OtaPackage {
  Esp32OtaPackage(this.notifyCharacteristic, this.writeCharacteristic);

  final BluetoothCharacteristic notifyCharacteristic;
  final BluetoothCharacteristic writeCharacteristic;

  final BleRepository _bleRepository = BleRepository();
  final FirmwareLoader _firmwareLoader = const FirmwareLoader();

  StreamSubscription? _subscription;
  bool _firmwareUpdateSucceeded = false;
  bool _cancelRequested = false;
  bool _isUpdating = false;

  final StreamController<int> _percentageController =
      StreamController<int>.broadcast();

  @override
  Stream<int> get percentageStream => _percentageController.stream;

  @override
  bool get isUpdating => _isUpdating;

  @override
  bool get firmwareUpdate => _firmwareUpdateSucceeded;

  @override
  Future<void> cancelUpdate() async {
    if (!_isUpdating) return;
    otaLogger.w('OTA update cancellation requested');
    _cancelRequested = true;
    await _subscription?.cancel();
    _subscription = null;
    _completeUpdate(cancelledValue);
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_percentageController.isClosed) {
      await _percentageController.close();
    }
  }

  void _emitPercentage(int value) {
    if (_percentageController.isClosed) return;
    _percentageController.add(value);
  }

  void _completeUpdate(int value) {
    if (_percentageController.isClosed) return;
    _isUpdating = false;
    _percentageController.add(value);
    _subscription?.cancel();
    _subscription = null;
    _percentageController.close();
  }

  void _handleUpdateError(Object error) {
    otaLogger.e(
      'OTA update aborted: Device either returned an error or did not acknowledge the operation. '
      'Some devices may not support acknowledgement.'
      'Please ensure the device firmware supports proper OTA acknowledgement flow.',
    );
    otaLogger.e('OTA update aborted', error: error);
    _firmwareUpdateSucceeded = false;
    _completeUpdate(_cancelRequested ? cancelledValue : failedValue);
  }

  Future<void> _runEspIdfUpdate({
    required FirmwareType firmwareType,
    required String? uri,
    required int mtuSize,
  }) async {
    final EspIdfOtaProtocol protocol = EspIdfOtaProtocol(
      bleRepository: _bleRepository,
      notifyCharacteristic: notifyCharacteristic,
      writeCharacteristic: writeCharacteristic,
      isCancelRequested: () => _cancelRequested,
      onProgress: _emitPercentage,
    );

    final List<Uint8List> binaryChunks = switch (firmwareType) {
      FirmwareType.assets => await _firmwareLoader.readChunkedBinaryFile(
        uri!,
        mtuSize,
      ),
      FirmwareType.filepicker => await _firmwareLoader.loadChunkedFromPicker(
        mtuSize,
      ),
      FirmwareType.url => await _firmwareLoader.loadChunkedFromUrl(
        uri!,
        mtuSize,
      ),
    };

    if (binaryChunks.isEmpty) {
      throw EmptyFirmwareException();
    }

    final bool succeeded = await protocol.update(
      binaryChunks: binaryChunks,
      mtuSize: mtuSize,
    );

    if (_cancelRequested) {
      _firmwareUpdateSucceeded = false;
      _completeUpdate(cancelledValue);
      return;
    }

    _firmwareUpdateSucceeded = succeeded;
    _completeUpdate(succeeded ? 100 : failedValue);
  }

  Future<void> _runArduinoUpdate({
    required FirmwareType firmwareType,
    required String? uri,
    required int mtuSize,
  }) async {
    otaLogger.i('Starting Arduino OTA — chunk size (MTU): $mtuSize');

    final Uint8List firmware = switch (firmwareType) {
      FirmwareType.assets => await _loadArduinoAssetFirmware(uri!),
      FirmwareType.filepicker => await _firmwareLoader.loadRawFromPicker(
        mtuSize,
      ),
      FirmwareType.url => await _firmwareLoader.loadRawFromUrl(uri!),
    };

    if (firmware.isEmpty) {
      throw EmptyFirmwareException();
    }

    final int firmwareByteLength = firmware.length;
    final int totalSegmentCount =
        (firmwareByteLength / ArduinoOtaProtocol.firmwareSegmentSize).ceil();
    otaLogger.d(
      'Firmware length: $firmwareByteLength bytes, '
      'segments: $totalSegmentCount',
    );

    final ArduinoOtaProtocol protocol = ArduinoOtaProtocol(
      bleRepository: _bleRepository,
      writeCharacteristic: writeCharacteristic,
      isCancelRequested: () => _cancelRequested,
    );

    await notifyCharacteristic.setNotifyValue(true);
    _subscription = notifyCharacteristic.onValueReceived.listen((value) async {
      if (_cancelRequested) {
        otaLogger.w('OTA update cancelled while sending firmware');
        _firmwareUpdateSucceeded = false;
        _completeUpdate(cancelledValue);
        return;
      }

      try {
        verboseTrace('Received notification value: $value');
        final int reportedSegmentIndex = (value[1] << 8) | value[2];
        final double progress =
            (reportedSegmentIndex / totalSegmentCount) * 100;
        final int roundedProgress = progress.round();
        otaLogger.d(
          'Segment $reportedSegmentIndex/$totalSegmentCount — $roundedProgress%',
        );
        _emitPercentage(roundedProgress);

        if (value[0] == 0xF1) {
          otaLogger.d('Next segment requested: $reportedSegmentIndex');
          await protocol.sendFirmwareSegment(
            reportedSegmentIndex,
            firmware,
            mtuSize,
          );
        }
        if (value[0] == 0x0F) {
          otaLogger.i('OTA update complete');
          _firmwareUpdateSucceeded = true;
          _completeUpdate(100);
        }
        if (value[0] == 0xF2) {
          otaLogger.i('New bin file installation begins on ESP32');
        }
      } catch (e) {
        _handleUpdateError(e);
      }
    });

    await protocol.sendHandshake(
      firmwareByteLength: firmwareByteLength,
      totalSegmentCount: totalSegmentCount,
      mtuSize: mtuSize,
    );

    const int initialSegmentIndex = 0;
    await protocol.sendFirmwareSegment(initialSegmentIndex, firmware, mtuSize);
    _emitPercentage(0);
    otaLogger.d('Started segment $initialSegmentIndex/$totalSegmentCount — 0%');
  }

  Future<Uint8List> _loadArduinoAssetFirmware(String uri) async {
    final firmware = await _firmwareLoader.loadBytesFromAsset(uri);
    verboseTrace('Loaded firmware bytes: $firmware');
    otaLogger.d('Firmware length: ${firmware.length} bytes');
    return firmware;
  }

  @override
  Future<void> updateFirmware(
    BluetoothDevice device,
    UpdateType updateType,
    FirmwareType firmwareType, {
    String? uri,
    int mtuSize = 500,
  }) async {
    if (firmwareType != FirmwareType.filepicker &&
        (uri == null || uri.isEmpty)) {
      throw OtaException('uri is required for the specified firmware type.');
    }

    final int maxChunkSize = updateType == UpdateType.arduino
        ? maxMtuSize - arduinoHeaderSize
        : maxMtuSize;
    if (mtuSize < 1 || mtuSize > maxChunkSize) {
      throw OtaException(
        'mtuSize must be between 1 and $maxChunkSize bytes for '
        '${updateType.name} (got $mtuSize).',
      );
    }

    _cancelRequested = false;
    _firmwareUpdateSucceeded = false;
    _isUpdating = true;

    try {
      switch (updateType) {
        case UpdateType.espidf:
          await _runEspIdfUpdate(
            firmwareType: firmwareType,
            uri: uri,
            mtuSize: mtuSize,
          );
        case UpdateType.arduino:
          await _runArduinoUpdate(
            firmwareType: firmwareType,
            uri: uri,
            mtuSize: mtuSize,
          );
      }
    } catch (e) {
      _handleUpdateError(e);
    }
  }
}
