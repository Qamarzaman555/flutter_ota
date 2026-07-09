import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_ota/src/transport/ble_repository.dart';

/// Arduino OTA transfer logic.
///
/// Terminology used in this protocol:
/// * **Firmware segment** — a fixed-size slice of the binary (see
///   [firmwareSegmentSize]) that the device acknowledges before requesting the
///   next one.
/// * **BLE packet** — one characteristic write within a segment (`mtuSize` bytes
///   of payload plus the 2-byte `0xFB` header).
class ArduinoOtaProtocol {
  ArduinoOtaProtocol({
    required BleRepository bleRepository,
    required BluetoothCharacteristic writeCharacteristic,
    required bool Function() isCancelRequested,
  }) : _bleRepository = bleRepository,
       _writeCharacteristic = writeCharacteristic,
       _isCancelRequested = isCancelRequested;

  /// Bytes of firmware sent per device-acknowledged segment.
  static const int firmwareSegmentSize = 16000;

  final BleRepository _bleRepository;
  final BluetoothCharacteristic _writeCharacteristic;
  final bool Function() _isCancelRequested;

  /// Sends one firmware segment as a sequence of BLE packets, then the `0xFC`
  /// segment-complete marker.
  Future<void> sendFirmwareSegment(
    int segmentIndex,
    Uint8List firmware,
    int mtuSize,
  ) async {
    if (_isCancelRequested()) {
      otaLogger.w('sendFirmwareSegment aborted due to cancellation');
      return;
    }

    final int segmentStart = segmentIndex * firmwareSegmentSize;
    int segmentEnd = (segmentIndex + 1) * firmwareSegmentSize;
    if (firmware.length < segmentEnd) {
      segmentEnd = firmware.length;
    }
    final int segmentLength = segmentEnd - segmentStart;
    final int blePacketCount = segmentLength ~/ mtuSize;

    final int totalSegmentCount = (firmware.length / firmwareSegmentSize)
        .ceil();
    final int overallProgress = totalSegmentCount == 0
        ? 0
        : (((segmentIndex + 1) / totalSegmentCount) * 100).round();
    otaLogger.d(
      'Segment $segmentIndex: $blePacketCount full BLE packets '
      '— overall $overallProgress%',
    );

    for (int packetIndex = 0; packetIndex < blePacketCount; packetIndex++) {
      verboseTrace(
        'BLE packet $packetIndex/$blePacketCount in segment $segmentIndex '
        '— overall $overallProgress%',
      );
      final Uint8List packet = Uint8List(mtuSize + arduinoHeaderSize);
      packet[0] = 0xFB;
      packet[1] = packetIndex;
      final int payloadStart = segmentStart + (mtuSize * packetIndex);
      packet.setRange(2, 2 + mtuSize, firmware, payloadStart);

      verboseTrace(
        'Writing BLE packet, payload length is ${packet.length} '
        '— overall $overallProgress%',
      );
      await _bleRepository.writeDataCharacteristic(
        _writeCharacteristic,
        packet,
      );
    }

    final int remainderBytes = segmentLength % mtuSize;
    if (remainderBytes != 0) {
      verboseTrace('Writing remainder BLE packet for segment $segmentIndex');
      final Uint8List packet = Uint8List(remainderBytes + arduinoHeaderSize);
      packet[0] = 0xFB;
      packet[1] = blePacketCount;
      final int payloadStart = segmentStart + (mtuSize * blePacketCount);
      packet.setRange(2, 2 + remainderBytes, firmware, payloadStart);

      verboseTrace('Writing remainder BLE packet payload');
      await _bleRepository.writeDataCharacteristic(
        _writeCharacteristic,
        packet,
      );
    }

    final Uint8List segmentCompleteMarker = Uint8List.fromList([
      0xFC,
      (segmentLength ~/ 256),
      (segmentLength % 256),
      (segmentIndex ~/ 256),
      (segmentIndex % 256),
    ]);

    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      segmentCompleteMarker,
    );
    verboseTrace('Sent segment-complete marker: $segmentCompleteMarker');
  }

  /// Sends the Arduino OTA handshake (`0xFD`, file size, OTA info).
  Future<void> sendHandshake({
    required int firmwareByteLength,
    required int totalSegmentCount,
    required int mtuSize,
  }) async {
    final Uint8List startCommand = Uint8List(1)..[0] = 0xFD;
    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      startCommand,
    );

    final Uint8List fileSizePacket = Uint8List(5)
      ..[0] = 0xFE
      ..[1] = (firmwareByteLength >> 24) & 0xFF
      ..[2] = (firmwareByteLength >> 16) & 0xFF
      ..[3] = (firmwareByteLength >> 8) & 0xFF
      ..[4] = firmwareByteLength & 0xFF;
    verboseDebug('Sending file size packet: $fileSizePacket');
    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      fileSizePacket,
    );

    final Uint8List otaInfoPacket = Uint8List(5)
      ..[0] = 0xFF
      ..[1] = totalSegmentCount ~/ 256
      ..[2] = totalSegmentCount % 256
      ..[3] = mtuSize ~/ 256
      ..[4] = mtuSize % 256;
    verboseDebug('Sending OTA info packet: $otaInfoPacket');
    await _bleRepository.writeDataCharacteristic(
      _writeCharacteristic,
      otaInfoPacket,
    );
  }
}
