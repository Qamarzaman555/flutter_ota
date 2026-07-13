import 'dart:typed_data';

import 'package:flutter_ota/src/core/ota_protocol.dart';
import 'package:flutter_ota/src/core/ota_transport.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/constants.dart';

/// ESP-IDF OTA transfer logic.
class EspIdfOtaProtocol implements OtaProtocol {
  @override
  int get maxWriteSize => maxMtuSize;

  @override
  Future<void> cancel() async {
    // Cancellation is cooperative via [isCancelRequested] in [performUpdate].
  }

  @override
  Future<bool> performUpdate({
    required OtaTransport transport,
    required Uint8List firmware,
    required int mtuSize,
    required bool Function() isCancelRequested,
    required void Function(int percent) onProgress,
  }) async {
    otaLogger.i('Starting ESP-IDF OTA — chunk size (MTU): $mtuSize');

    final List<Uint8List> binaryChunks = _chunkFirmware(firmware, mtuSize);

    final Uint8List mtuPacket = Uint8List(2)
      ..[0] = mtuSize & 0xFF
      ..[1] = (mtuSize >> 8) & 0xFF;

    await transport.writeData(mtuPacket);
    await transport.writeControl(Uint8List.fromList([1]));

    Uint8List value = await transport
        .readControl()
        .timeout(const Duration(seconds: 10));
    if (value.isEmpty) {
      otaLogger.e('OTA update failed: empty control characteristic read');
      return false;
    }
    otaLogger.d('Control characteristic returned: ${value[0]}');

    int chunkIndex = 0;
    otaLogger.i('Sending ${binaryChunks.length} firmware chunks');
    for (final Uint8List chunk in binaryChunks) {
      if (isCancelRequested()) {
        otaLogger.w('OTA update cancelled while sending firmware');
        return false;
      }

      if (chunk.length > mtuSize) {
        otaLogger.e(
          'OTA update failed: chunk size ${chunk.length} exceeds mtuSize $mtuSize',
        );
        return false;
      }

      await transport.writeData(chunk);
      chunkIndex++;

      final double progress = (chunkIndex / binaryChunks.length) * 100;
      final int roundedProgress = progress.round();
      otaLogger.d(
        'Writing chunk $chunkIndex/${binaryChunks.length} — $roundedProgress%',
      );
      onProgress(roundedProgress);
    }

    await transport.writeControl(Uint8List.fromList([4]));

    value = await transport
        .readControl()
        .timeout(const Duration(seconds: 600));
    if (value.isEmpty) {
      otaLogger.e('OTA update failed: empty final control characteristic read');
      return false;
    }
    otaLogger.d('Control characteristic returned: ${value[0]}');

    if (value[0] == 5) {
      otaLogger.i('OTA update finished successfully');
      return true;
    }

    otaLogger.e('OTA update failed (unexpected status ${value[0]})');
    return false;
  }

  /// Splits [bytes] into fixed-size chunks for ESP-IDF BLE transfer.
  List<Uint8List> _chunkFirmware(List<int> bytes, int chunkSize) {
    final List<Uint8List> chunks = [];
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final int end = i + chunkSize < bytes.length
          ? i + chunkSize
          : bytes.length;
      chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return chunks;
  }
}
