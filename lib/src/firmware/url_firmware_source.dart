import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:flutter_ota/src/core/firmware_source.dart';
import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';

/// Downloads firmware from an HTTP(S) URL.
class UrlFirmwareSource implements FirmwareSource {
  UrlFirmwareSource(this.url);

  final String url;

  @override
  Future<Uint8List> load() async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Uint8List bytes = Uint8List.fromList(response.bodyBytes);
        if (bytes.isEmpty) {
          throw EmptyFirmwareException(
            'Downloaded firmware is empty (0 bytes) from $url.',
          );
        }
        return bytes;
      }

      throw FirmwareDownloadException(
        'HTTP Error: ${response.statusCode} - ${response.reasonPhrase}',
        statusCode: response.statusCode,
      );
    } on OtaException {
      rethrow;
    } catch (e) {
      throw FirmwareDownloadException(
        'Error fetching firmware from URL',
        cause: e,
      );
    }
  }
}
