import 'dart:typed_data';

import 'package:flutter_ota/src/core/ota_client.dart';
import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/models/constants.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  Uint8List firmware() => Uint8List.fromList(List<int>.generate(32, (i) => i));

  group('OtaClient.run', () {
    test('rejects an out-of-range mtuSize before starting', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final FakeProtocol protocol = FakeProtocol(maxWrite: 512);
      final OtaClient client = OtaClient(
        transport: transport,
        protocol: protocol,
        source: FakeFirmwareSource(firmware()),
      );

      await expectLater(
        client.run(mtuSize: 0),
        throwsA(isA<OtaException>()),
      );
      await expectLater(
        client.run(mtuSize: 513),
        throwsA(isA<OtaException>()),
      );
      expect(protocol.performCalled, isFalse);
    });

    test('emits 100 and reports success on a successful update', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final FakeProtocol protocol = FakeProtocol(
        result: true,
        emitProgress: <int>[25, 50, 75],
      );
      final OtaClient client = OtaClient(
        transport: transport,
        protocol: protocol,
        source: FakeFirmwareSource(firmware()),
      );

      final Future<List<int>> events = client.percentageStream.toList();

      await client.run(mtuSize: 128);

      expect(await events, <int>[25, 50, 75, 100]);
      expect(client.firmwareUpdate, isTrue);
      expect(client.isUpdating, isFalse);
      expect(transport.prepareCalls, 1);
      expect(transport.startInboundCalls, 1);
      expect(transport.disposeCalls, 1);
    });

    test('emits failedValue when the protocol reports failure', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final OtaClient client = OtaClient(
        transport: transport,
        protocol: FakeProtocol(result: false),
        source: FakeFirmwareSource(firmware()),
      );

      final Future<List<int>> events = client.percentageStream.toList();

      await client.run(mtuSize: 128);

      expect(await events, contains(failedValue));
      expect(client.firmwareUpdate, isFalse);
    });

    test('emits failedValue when firmware is empty', () async {
      final FakeOtaTransport transport = FakeOtaTransport();
      final FakeProtocol protocol = FakeProtocol();
      final OtaClient client = OtaClient(
        transport: transport,
        protocol: protocol,
        source: FakeFirmwareSource(Uint8List(0)),
      );

      final Future<List<int>> events = client.percentageStream.toList();

      await client.run(mtuSize: 128);

      expect(await events, <int>[failedValue]);
      expect(protocol.performCalled, isFalse);
      expect(transport.disposeCalls, 1);
    });
  });

  group('OtaClient.cancel', () {
    test('is a no-op when no update is running', () async {
      final OtaClient client = OtaClient(
        transport: FakeOtaTransport(),
        protocol: FakeProtocol(),
        source: FakeFirmwareSource(firmware()),
      );

      await client.cancel();
      expect(client.isUpdating, isFalse);
    });
  });
}
