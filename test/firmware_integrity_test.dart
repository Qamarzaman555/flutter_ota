import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota/src/core/crc16.dart';
import 'package:flutter_ota/src/core/firmware_hash.dart';
import 'package:flutter_ota/src/core/ota_client.dart';
import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_ota/src/models/firmware_integrity.dart';
import 'package:flutter_ota/src/protocol/arduino_ota_protocol.dart';
import 'package:flutter_ota/src/protocol/espidf_ota_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('crc16Modbus', () {
    test('matches known Modbus vector for "123456789"', () {
      // CRC-16/MODBUS reference: 0x4B37 for ASCII "123456789"
      expect(crc16Modbus(utf8Bytes('123456789')), 0x4B37);
    });

    test('appendCrc16 appends big-endian CRC', () {
      final List<int> withCrc = appendCrc16(<int>[0x01, 0x02]);
      expect(withCrc.length, 4);
      final int crc = crc16Modbus(<int>[0x01, 0x02]);
      expect(withCrc[2], (crc >> 8) & 0xFF);
      expect(withCrc[3], crc & 0xFF);
    });
  });

  group('FirmwareIntegrityConfig', () {
    test('none disables all features', () {
      expect(FirmwareIntegrityConfig.none.features, isEmpty);
      expect(FirmwareIntegrityConfig.none.verifyBeforeTransfer, isFalse);
      expect(FirmwareIntegrityConfig.none.packetCrc16, isFalse);
      expect(FirmwareIntegrityConfig.none.verifyAfterFlash, isFalse);
    });

    test('validate requires a digest when any SHA feature is set', () {
      expect(
        () => FirmwareIntegrityConfig(
          features: {IntegrityFeature.shaBeforeTransfer},
        ).validate(),
        throwsA(isA<OtaException>()),
      );
    });

    test('parses hex digest and supports independent feature combos', () {
      final String hex = List<String>.generate(
        32,
        (i) => i.toRadixString(16).padLeft(2, '0'),
      ).join();

      final FirmwareIntegrityConfig crcOnly = FirmwareIntegrityConfig(
        features: {IntegrityFeature.packetCrc16},
      );
      crcOnly.validate();
      expect(crcOnly.packetCrcOverhead, crc16Size);
      expect(crcOnly.requiresExpectedSha256, isFalse);

      final FirmwareIntegrityConfig shaStartOnly = FirmwareIntegrityConfig(
        features: {IntegrityFeature.shaBeforeTransfer},
        expectedSha256Hex: hex,
      );
      shaStartOnly.validate();
      expect(shaStartOnly.requiresDeviceSupport, isFalse);

      final FirmwareIntegrityConfig shaEndOnly = FirmwareIntegrityConfig(
        features: {IntegrityFeature.shaAfterFlash},
        expectedSha256Hex: hex,
      );
      shaEndOnly.validate();
      expect(shaEndOnly.requiresDeviceSupport, isTrue);

      final FirmwareIntegrityConfig all = FirmwareIntegrityConfig(
        features: {
          IntegrityFeature.shaBeforeTransfer,
          IntegrityFeature.shaAfterFlash,
          IntegrityFeature.packetCrc16,
        },
        expectedSha256Hex: hex,
      );
      all.validate();
      expect(all.resolvedExpectedSha256, hasLength(sha256DigestSize));
      expect(all.packetCrc16, isTrue);
    });

    test('rejects malformed hex', () {
      expect(
        () => FirmwareIntegrityConfig(
          features: {IntegrityFeature.shaAfterFlash},
          expectedSha256Hex: 'deadbeef',
        ).validate(),
        throwsA(isA<OtaException>()),
      );
    });
  });

  group('OtaClient pre-transfer SHA-256', () {
    test('throws FirmwareHashMismatchException on bad digest', () async {
      final Uint8List firmware = Uint8List.fromList(
        List<int>.generate(32, (i) => i),
      );
      final String wrongHex = List<String>.filled(64, '0').join();

      final OtaClient client = OtaClient(
        transport: FakeOtaTransport(),
        protocol: FakeProtocol(),
        source: FakeFirmwareSource(firmware),
      );

      final Future<List<int>> events = client.percentageStream.toList();

      await expectLater(
        client.run(
          mtuSize: 128,
          integrity: FirmwareIntegrityConfig(
            features: {IntegrityFeature.shaBeforeTransfer},
            expectedSha256Hex: wrongHex,
          ),
        ),
        throwsA(isA<FirmwareHashMismatchException>()),
      );

      expect(await events, contains(failedValue));
    });

    test('proceeds when digest matches', () async {
      final Uint8List firmware = Uint8List.fromList(
        List<int>.generate(32, (i) => i),
      );
      final String hex = sha256.convert(firmware).toString();

      final FakeProtocol protocol = FakeProtocol(result: true);
      final OtaClient client = OtaClient(
        transport: FakeOtaTransport(),
        protocol: protocol,
        source: FakeFirmwareSource(firmware),
      );

      await client.run(
        mtuSize: 128,
        integrity: FirmwareIntegrityConfig(
          features: {IntegrityFeature.shaBeforeTransfer},
          expectedSha256Hex: hex,
        ),
      );

      expect(protocol.performCalled, isTrue);
      expect(client.firmwareUpdate, isTrue);
    });
  });

  group('ArduinoOtaProtocol integrity', () {
    test('default wire format has no CRC and no integrity prelude', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final ArduinoOtaProtocol protocol = ArduinoOtaProtocol();

      final Future<bool> result = protocol.performUpdate(
        transport: transport,
        firmware: Uint8List.fromList(List<int>.generate(64, (i) => i)),
        mtuSize: 32,
        isCancelRequested: () => false,
        onProgress: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      // Handshake only — no 0xF9 / 0xFA
      expect(transport.dataWrites.take(3).map((w) => w.first), <int>[
        0xFD,
        0xFE,
        0xFF,
      ]);
      expect(
        transport.dataWrites.where(
          (w) => w.first == arduinoIntegrityFlagsOpcode,
        ),
        isEmpty,
      );

      transport.emitInbound(<int>[0x0F]);
      expect(await result, isTrue);
    });

    test(
      'sends integrity flags, hash, and CRC on packets when enabled',
      () async {
        final Uint8List firmware = Uint8List.fromList(
          List<int>.generate(40, (i) => i),
        );
        final String hex = sha256.convert(firmware).toString();
        final FakeOtaTransport transport = FakeOtaTransport();
        final ArduinoOtaProtocol protocol = ArduinoOtaProtocol(
          integrity: FirmwareIntegrityConfig(
            features: {
              IntegrityFeature.packetCrc16,
              IntegrityFeature.shaAfterFlash,
            },
            expectedSha256Hex: hex,
          ),
        );

        expect(
          protocol.maxWriteSize,
          maxMtuSize - arduinoHeaderSize - crc16Size,
        );

        final Future<bool> result = protocol.performUpdate(
          transport: transport,
          firmware: firmware,
          mtuSize: 20,
          isCancelRequested: () => false,
          onProgress: (_) {},
        );

        await Future<void>.delayed(Duration.zero);

        expect(transport.dataWrites[3].first, arduinoIntegrityFlagsOpcode);
        expect(
          transport.dataWrites[3][1],
          integrityFlagPacketCrc16 | integrityFlagShaAfterFlash,
        );
        expect(transport.dataWrites[4].first, arduinoExpectedHashOpcode);
        expect(transport.dataWrites[4].length, 1 + sha256DigestSize);

        final Uint8List firstDataPacket = transport.dataWrites.firstWhere(
          (w) => w.isNotEmpty && w.first == 0xFB,
        );
        // header(2) + payload(20) + crc(2)
        expect(firstDataPacket.length, 24);
        final List<int> payload = firstDataPacket.sublist(2, 22);
        final int crc = crc16Modbus(payload);
        expect(firstDataPacket[22], (crc >> 8) & 0xFF);
        expect(firstDataPacket[23], crc & 0xFF);

        transport.emitInbound(<int>[0x0F]);
        expect(await result, isTrue);
      },
    );

    test('retransmits a single packet on CRC NACK', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final ArduinoOtaProtocol protocol = ArduinoOtaProtocol(
        integrity: FirmwareIntegrityConfig(
          features: {IntegrityFeature.packetCrc16},
          maxPacketRetries: 3,
        ),
      );

      final Future<bool> result = protocol.performUpdate(
        transport: transport,
        firmware: Uint8List.fromList(List<int>.generate(40, (i) => i)),
        mtuSize: 20,
        isCancelRequested: () => false,
        onProgress: (_) {},
      );

      await Future<void>.delayed(Duration.zero);

      final Uint8List packet0 = transport.dataWrites.firstWhere(
        (w) => w.length > 1 && w[0] == 0xFB && w[1] == 0,
      );
      final int writesBeforeNack = transport.dataWrites.length;

      transport.emitInbound(<int>[arduinoPacketNackOpcode, 0x00]);
      await Future<void>.delayed(Duration.zero);

      expect(transport.dataWrites.length, writesBeforeNack + 1);
      expect(transport.dataWrites.last, packet0);

      transport.emitInbound(<int>[0x0F]);
      expect(await result, isTrue);
    });

    test('fails on post-flash hash mismatch opcode', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final ArduinoOtaProtocol protocol = ArduinoOtaProtocol(
        integrity: FirmwareIntegrityConfig(
          features: {IntegrityFeature.shaAfterFlash},
          expectedSha256Bytes: List<int>.filled(32, 1),
        ),
      );

      final Future<bool> result = protocol.performUpdate(
        transport: transport,
        firmware: Uint8List.fromList(<int>[1, 2, 3]),
        mtuSize: 32,
        isCancelRequested: () => false,
        onProgress: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      transport.emitInbound(<int>[arduinoHashMismatchOpcode]);
      expect(await result, isFalse);
    });
  });

  group('EspIdfOtaProtocol integrity', () {
    test('appends CRC and sends expected hash when enabled', () async {
      final Uint8List firmware = Uint8List.fromList(
        List<int>.generate(10, (i) => i),
      );
      final String hex = sha256.convert(firmware).toString();
      final FakeOtaTransport transport = FakeOtaTransport(
        controlReads: <List<int>>[
          <int>[espIdfControlAck], // BEGIN ack
          <int>[espIdfControlAck], // SET_HASH digest ack
          <int>[espIdfStatusSuccess],
        ],
      );

      final bool ok =
          await EspIdfOtaProtocol(
            integrity: FirmwareIntegrityConfig(
              features: {
                IntegrityFeature.packetCrc16,
                IntegrityFeature.shaAfterFlash,
              },
              expectedSha256Hex: hex,
            ),
          ).performUpdate(
            transport: transport,
            firmware: firmware,
            mtuSize: 4,
            isCancelRequested: () => false,
            onProgress: (_) {},
          );

      expect(ok, isTrue);
      expect(transport.controlWrites.map((c) => c.first), <int>[
        espIdfControlBegin,
        espIdfControlExpectedHash,
        espIdfControlFinish,
      ]);
      expect(espIdfControlExpectedHash, 7);
      // data: MTU packet, firmware chunks (with CRC), then 32-byte digest (PostSHA)
      expect(transport.dataWrites.first.length, 2); // MTU
      final Uint8List firstChunk = transport.dataWrites[1];
      expect(firstChunk.length, 4 + crc16Size);
      expect(
        firstChunk.sublist(4),
        appendCrc16(firstChunk.sublist(0, 4)).sublist(4),
      );
      expect(transport.dataWrites.last.length, sha256DigestSize);
    });

    test('sends expected hash after firmware chunks (PostSHA)', () async {
      final Uint8List firmware = Uint8List.fromList(<int>[0xE9, 2, 3, 4, 5, 6]);
      final String hex = sha256.convert(firmware).toString();
      final FakeOtaTransport transport = FakeOtaTransport(
        controlReads: <List<int>>[
          <int>[espIdfControlAck],
          <int>[espIdfControlAck],
          <int>[espIdfStatusSuccess],
        ],
      );

      await EspIdfOtaProtocol(
        integrity: FirmwareIntegrityConfig(
          features: {IntegrityFeature.shaAfterFlash},
          expectedSha256Hex: hex,
        ),
      ).performUpdate(
        transport: transport,
        firmware: firmware,
        mtuSize: 4,
        isCancelRequested: () => false,
        onProgress: (_) {},
      );

      // [0]=MTU, [1]=first image chunk must be 0xE9 (not digest)
      expect(transport.dataWrites[1].first, 0xE9);
      expect(
        transport.dataWrites.last,
        Uint8List.fromList(sha256.convert(firmware).bytes),
      );
      expect(transport.controlWrites.map((c) => c.first).toList(), <int>[
        espIdfControlBegin,
        espIdfControlExpectedHash, // 0x07 SET_HASH
        espIdfControlFinish,
      ]);
    });

    test('returns false on post-flash hash mismatch status', () async {
      final FakeOtaTransport transport = FakeOtaTransport(
        controlReads: <List<int>>[
          <int>[espIdfControlAck],
          <int>[espIdfControlAck],
          <int>[espIdfStatusHashMismatch],
        ],
      );

      final bool ok =
          await EspIdfOtaProtocol(
            integrity: FirmwareIntegrityConfig(
              features: {IntegrityFeature.shaAfterFlash},
              expectedSha256Bytes: List<int>.filled(32, 7),
            ),
          ).performUpdate(
            transport: transport,
            firmware: Uint8List.fromList(<int>[1, 2, 3, 4]),
            mtuSize: 4,
            isCancelRequested: () => false,
            onProgress: (_) {},
          );

      expect(ok, isFalse);
    });
  });

  group('firmware hash helpers', () {
    test('assertSha256Matches throws typed mismatch', () {
      expect(
        () => assertSha256Matches(
          actual: Uint8List.fromList(List<int>.filled(32, 1)),
          expected: List<int>.filled(32, 2),
          phase: 'before-transfer',
        ),
        throwsA(isA<FirmwareHashMismatchException>()),
      );
    });
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
