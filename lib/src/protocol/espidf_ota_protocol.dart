import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/transport/ble_repository.dart';

/// ESP-IDF OTA transfer logic.
class EspIdfOtaProtocol {
  EspIdfOtaProtocol({
    required BleRepository bleRepository,
    required BluetoothCharacteristic notifyCharacteristic,
    required BluetoothCharacteristic writeCharacteristic,
    required bool Function() isCancelRequested,
    required void Function(int) onProgress,
  }) : _bleRepository = bleRepository,
       _notifyCharacteristic = notifyCharacteristic,
       _writeCharacteristic = writeCharacteristic,
       _isCancelRequested = isCancelRequested,
       _onProgress = onProgress;

  final BleRepository _bleRepository;
  final BluetoothCharacteristic _notifyCharacteristic;
  final BluetoothCharacteristic _writeCharacteristic;
  final bool Function() _isCancelRequested;
  final void Function(int) _onProgress;

  /// Returns `true` when the device acknowledges a successful update.
  Future<bool> update({
    required List<Uint8List> binaryChunks,
    required int mtuSize,
  }) async {
    otaLogger.i('Starting ESP-IDF OTA — chunk size (MTU): $mtuSize');

    final Uint8List mtuPacket = Uint8List(2)
      ..[0] = mtuSize & 0xFF
      ..[1] = (mtuSize >> 8) & 0xFF;

    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      mtuPacket,
    );
    await _bleRepository.writeDataCharacteristic(
      _notifyCharacteristic,
      Uint8List.fromList([1]),
    );

    List<int> value = await _bleRepository
        .readCharacteristic(_notifyCharacteristic)
        .timeout(const Duration(seconds: 10));
    otaLogger.d('Control characteristic returned: ${value[0]}');

    int packageNumber = 0;
    otaLogger.i('Sending ${binaryChunks.length} firmware chunks');
    for (final Uint8List chunk in binaryChunks) {
      if (_isCancelRequested()) {
        otaLogger.w('OTA update cancelled while sending firmware');
        return false;
      }

      await _bleRepository.writeDataCharacteristic(_writeCharacteristic, chunk);
      packageNumber++;

      final double progress = (packageNumber / binaryChunks.length) * 100;
      final int roundedProgress = progress.round();
      otaLogger.d(
        'Writing package $packageNumber/${binaryChunks.length} — $roundedProgress%',
      );
      _onProgress(roundedProgress);
    }

    await _bleRepository.writeDataCharacteristic(
      _notifyCharacteristic,
      Uint8List.fromList([4]),
    );

    value = await _bleRepository
        .readCharacteristic(_notifyCharacteristic)
        .timeout(const Duration(seconds: 600));
    otaLogger.d('Control characteristic returned: ${value[0]}');

    if (value[0] == 5) {
      otaLogger.i('OTA update finished successfully');
      return true;
    }

    otaLogger.e('OTA update failed (unexpected status ${value[0]})');
    return false;
  }
}
