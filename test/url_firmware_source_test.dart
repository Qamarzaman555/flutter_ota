import 'dart:io';

import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/firmware/url_firmware_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String urlFor(String path) =>
      'http://${server.address.host}:${server.port}$path';

  test('loads binary firmware', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add([0xE9, 0x06, 0x02, 0x20]);
      await request.response.close();
    });

    final bytes = await UrlFirmwareSource(urlFor('/fw.bin')).load();
    expect(bytes, [0xE9, 0x06, 0x02, 0x20]);
  });

  test('rejects HTML payloads with a clear error', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType('text', 'html');
      request.response.write(
        '<!DOCTYPE html><html><body>drive viewer</body></html>',
      );
      await request.response.close();
    });

    expect(
      () => UrlFirmwareSource(urlFor('/view')).load(),
      throwsA(
        isA<FirmwareDownloadException>().having(
          (e) => e.message,
          'message',
          contains('HTML instead of a firmware binary'),
        ),
      ),
    );
  });

  test('rejects HTML even when content-type is missing', () async {
    server.listen((request) async {
      request.response.write('<html><body>no type</body></html>');
      await request.response.close();
    });

    expect(
      () => UrlFirmwareSource(urlFor('/page')).load(),
      throwsA(isA<FirmwareDownloadException>()),
    );
  });
}
