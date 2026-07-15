import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_ota/src/core/crc16.dart';
import 'package:flutter_ota/src/core/firmware_chunker.dart';
import 'package:flutter_ota/src/core/firmware_hash.dart';
import 'package:flutter_ota/src/core/ota_protocol.dart';
import 'package:flutter_ota/src/core/ota_transport.dart';
import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_ota/src/models/firmware_integrity.dart';

/// ESP-IDF OTA transfer logic.
class EspIdfOtaProtocol implements OtaProtocol {
  /// Creates an ESP-IDF protocol instance.
  ///
  /// Pass [integrity] to enable optional CRC / post-flash SHA features that the
  /// paired firmware understands. Default is [FirmwareIntegrityConfig.none].
  EspIdfOtaProtocol({this.integrity = FirmwareIntegrityConfig.none});

  /// Integrity features active for this session.
  final FirmwareIntegrityConfig integrity;

  @override
  int get maxWriteSize => maxMtuSize - integrity.packetCrcOverhead;

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
    if (integrity.features.isNotEmpty) {
      otaLogger.i('Integrity features: ${integrity.features}');
    }

    final int totalChunks = chunkCount(firmware.length, mtuSize);
    final List<Uint8List> sentChunks = <Uint8List>[];
    final Map<int, int> chunkAttempts = <int, int>{};
    PacketCrcException? crcError;

    StreamSubscription<Uint8List>? nackSubscription;
    if (integrity.packetCrc16) {
      nackSubscription = transport.inbound.listen((value) async {
        if (value.isEmpty || value[0] != espIdfPacketNackOpcode) return;
        if (value.length < 3) {
          otaLogger.w('Ignoring short ESP-IDF CRC NACK');
          return;
        }
        final int chunkIndex = (value[1] << 8) | value[2];
        if (chunkIndex < 0 || chunkIndex >= sentChunks.length) {
          otaLogger.w('Ignoring out-of-range ESP-IDF NACK index $chunkIndex');
          return;
        }
        if (crcError != null) return;

        final int retransmits = chunkAttempts[chunkIndex] ?? 0;
        if (retransmits >= integrity.maxPacketRetries) {
          crcError = PacketCrcException(
            packetIndex: chunkIndex,
            attempts: retransmits + 1,
          );
          return;
        }
        chunkAttempts[chunkIndex] = retransmits + 1;
        otaLogger.w(
          'CRC NACK for chunk $chunkIndex — retransmitting '
          '(${retransmits + 1}/${integrity.maxPacketRetries})',
        );
        await transport.writeData(sentChunks[chunkIndex]);
      });
    }

    try {
      final Uint8List mtuPacket = Uint8List(2)
        ..[0] = mtuSize & 0xFF
        ..[1] = (mtuSize >> 8) & 0xFF;

      await transport.writeData(mtuPacket);
      await transport.writeControl(Uint8List.fromList([espIdfControlBegin]));

      Uint8List value = await transport.readControl().timeout(
        const Duration(seconds: 10),
      );
      if (value.isEmpty) {
        otaLogger.e('OTA update failed: empty control characteristic read');
        return false;
      }
      otaLogger.d('Control characteristic returned: ${value[0]}');

      int chunkIndex = 0;
      otaLogger.i('Sending $totalChunks firmware chunks');
      for (final Uint8List chunk in chunkFirmware(firmware, mtuSize)) {
        if (isCancelRequested()) {
          otaLogger.w('OTA update cancelled while sending firmware');
          return false;
        }
        if (crcError != null) {
          otaLogger.e('ESP-IDF OTA failed', error: crcError);
          return false;
        }

        final Uint8List wire = integrity.packetCrc16
            ? Uint8List.fromList(appendCrc16(chunk))
            : chunk;

        sentChunks.add(wire);
        await transport.writeData(wire);
        chunkIndex++;

        final double progress = (chunkIndex / totalChunks) * 100;
        final int roundedProgress = progress.round();
        otaLogger.d(
          'Writing chunk $chunkIndex/$totalChunks — $roundedProgress%',
        );
        onProgress(roundedProgress);
      }

      // Brief settle window for late NACKs before finish.
      if (integrity.packetCrc16) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (crcError != null) {
          otaLogger.e('ESP-IDF OTA failed', error: crcError);
          return false;
        }
      }

      // PostSHA: arm SET_HASH (0x07), then 32-byte digest on data, then DONE.
      // Opcode must be 7 — 2 is device→phone ACK and must never be sent as
      // SET_HASH.
      if (integrity.verifyAfterFlash) {
        final List<int> digest =
            integrity.resolvedExpectedSha256 ?? sha256Of(firmware);
        final String digestHex = sha256ToHex(digest);
        otaLogger.i(
          'SHA-256 to send to firmware after image (PostSHA): $digestHex',
        );
        await transport.writeControl(
          Uint8List.fromList([espIdfControlExpectedHash]),
        );
        await transport.writeData(Uint8List.fromList(digest));

        final Uint8List hashAck = await transport.readControl().timeout(
          const Duration(seconds: 10),
        );
        if (hashAck.isEmpty || hashAck[0] != espIdfControlAck) {
          otaLogger.e(
            'Device did not ACK expected SHA-256 '
            '(status ${hashAck.isEmpty ? 'empty' : hashAck[0]})',
          );
          return false;
        }
        otaLogger.d('Sent expected SHA-256 for post-flash verify: $digestHex');
      }

      await transport.writeControl(Uint8List.fromList([espIdfControlFinish]));

      value = await transport.readControl().timeout(
        const Duration(seconds: 600),
      );
      if (value.isEmpty) {
        otaLogger.e(
          'OTA update failed: empty final control characteristic read',
        );
        return false;
      }
      otaLogger.d('Control characteristic returned: ${value[0]}');

      if (value[0] == espIdfStatusSuccess) {
        otaLogger.i('OTA update finished successfully');
        return true;
      }

      if (value[0] == espIdfStatusHashMismatch) {
        final List<int>? expected = integrity.resolvedExpectedSha256;
        final String transferredHex = sha256ToHex(sha256Of(firmware));
        final String expectedHex = expected != null
            ? sha256ToHex(expected)
            : '(none configured)';
        otaLogger.e(
          'Device reported post-flash SHA-256 mismatch.\n'
          '  Expected (sent to device): $expectedHex\n'
          '  SHA-256 of bytes transferred by app: $transferredHex\n'
          '  If those two differ → wrong expectedSha256 on the app/server.\n'
          '  If they match → device hashed a different flash region/content '
          '(or transfer corruption).',
        );
        return false;
      }

      otaLogger.e('OTA update failed (unexpected status ${value[0]})');
      return false;
    } finally {
      await nackSubscription?.cancel();
    }
  }
}
