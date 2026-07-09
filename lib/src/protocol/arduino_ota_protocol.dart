import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_ota/src/transport/ble_repository.dart';

/// Arduino OTA transfer logic: slice firmware and write BLE packets.
class ArduinoOtaProtocol {
  ArduinoOtaProtocol({
    required BleRepository bleRepository,
    required BluetoothCharacteristic writeCharacteristic,
    required bool Function() isCancelRequested,
  }) : _bleRepository = bleRepository,
       _writeCharacteristic = writeCharacteristic,
       _isCancelRequested = isCancelRequested;

  /// Arduino firmware is transferred in fixed-size slices before BLE chunking.
  static const int partSize = 16000;

  final BleRepository _bleRepository;
  final BluetoothCharacteristic _writeCharacteristic;
  final bool Function() _isCancelRequested;

  Future<void> sendPart(int position, Uint8List data, int mtuSize) async {
    if (_isCancelRequested()) {
      otaLogger.w('sendPart aborted due to cancellation');
      return;
    }

    int start = position * partSize;
    int end = (position + 1) * partSize;
    if (data.length < end) {
      end = data.length;
    }
    final int parts = (end - start) ~/ mtuSize;

    final int fileParts = (data.length / partSize).ceil();
    final int overallProgress = fileParts == 0
        ? 0
        : (((position + 1) / fileParts) * 100).round();
    otaLogger.d('Parts to send: $parts — overall $overallProgress%');

    for (int i = 0; i < parts; i++) {
      verboseTrace('Created part $i — overall $overallProgress%');
      final Uint8List toSend = Uint8List(mtuSize + arduinoHeaderSize);
      toSend[0] = 0xFB;
      toSend[1] = i;
      final int chunkStart = (position * partSize) + (mtuSize * i);
      toSend.setRange(2, 2 + mtuSize, data, chunkStart);

      verboseTrace(
        'Writing data, payload length is ${toSend.length} — overall $overallProgress%',
      );
      await _bleRepository.writeDataCharacteristic(
        _writeCharacteristic,
        toSend,
      );
    }

    if ((end - start) % mtuSize != 0) {
      verboseTrace('Writing remainder part');
      final int rem = (end - start) % mtuSize;
      final Uint8List toSend = Uint8List(rem + arduinoHeaderSize);
      toSend[0] = 0xFB;
      toSend[1] = parts;
      final int chunkStart = (position * partSize) + (mtuSize * parts);
      toSend.setRange(2, 2 + rem, data, chunkStart);

      verboseTrace('Writing remainder payload');
      await _bleRepository.writeDataCharacteristic(
        _writeCharacteristic,
        toSend,
      );
    }

    final Uint8List update = Uint8List.fromList([
      0xFC,
      ((end - start) ~/ 256),
      ((end - start) % 256),
      (position ~/ 256),
      (position % 256),
    ]);

    await _bleRepository.writeDataCharacteristic(_writeCharacteristic, update);
    verboseTrace('Sent part update marker: $update');
  }

  Future<void> sendHandshake({
    required int fileLen,
    required int fileParts,
    required int mtuSize,
  }) async {
    final Uint8List byteListData = Uint8List(1)..[0] = 0xFD;
    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      byteListData,
    );

    final Uint8List fileSize = Uint8List(5)
      ..[0] = 0xFE
      ..[1] = (fileLen >> 24) & 0xFF
      ..[2] = (fileLen >> 16) & 0xFF
      ..[3] = (fileLen >> 8) & 0xFF
      ..[4] = fileLen & 0xFF;
    verboseDebug('Sending file size packet: $fileSize');
    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      fileSize,
    );

    final Uint8List otaInfo = Uint8List(5)
      ..[0] = 0xFF
      ..[1] = fileParts ~/ 256
      ..[2] = fileParts % 256
      ..[3] = mtuSize ~/ 256
      ..[4] = mtuSize % 256;
    verboseDebug('Sending OTA info packet: $otaInfo');
    await _bleRepository.writeDataCharacteristic(_writeCharacteristic, otaInfo);
  }
}
