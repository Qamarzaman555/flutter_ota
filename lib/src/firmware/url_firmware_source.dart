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
        _rejectNonBinaryPayload(response, bytes);
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

  /// Google Drive "view" / share links return HTML (often with a fresh nonce
  /// each request), which makes SHA-256 appear to change every download.
  void _rejectNonBinaryPayload(http.Response response, Uint8List bytes) {
    final String? contentType = response.headers['content-type']?.toLowerCase();
    final bool looksLikeHtml =
        (contentType != null && contentType.contains('text/html')) ||
        _startsWithHtml(bytes);
    if (!looksLikeHtml) return;

    throw FirmwareDownloadException(
      'URL returned HTML instead of a firmware binary. '
      'For Google Drive use a direct-download link, e.g. '
      'https://drive.google.com/uc?export=download&id=FILE_ID '
      '(not the /file/d/.../view share page).',
      statusCode: response.statusCode,
    );
  }

  static bool _startsWithHtml(Uint8List bytes) {
    // Skip UTF-8 BOM if present.
    int offset = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      offset = 3;
    }
    while (offset < bytes.length &&
        (bytes[offset] == 0x20 ||
            bytes[offset] == 0x09 ||
            bytes[offset] == 0x0A ||
            bytes[offset] == 0x0D)) {
      offset++;
    }
    if (bytes.length - offset < 5) return false;
    final String head = String.fromCharCodes(
      bytes.sublist(offset, offset + (bytes.length - offset).clamp(0, 15)),
    ).toLowerCase();
    return head.startsWith('<!doctype') || head.startsWith('<html');
  }
}
