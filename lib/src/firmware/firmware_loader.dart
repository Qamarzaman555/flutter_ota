import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';
import 'package:flutter_ota/src/models/firmware_type.dart';

/// Loads firmware binaries from assets, the file picker, or HTTP URLs.
///
/// Every source returns the raw firmware bytes as a [Uint8List]. Any
/// protocol-specific chunking is performed downstream by the caller (e.g.
/// [chunkFirmware] for ESP-IDF transfers).
class FirmwareLoader {
  const FirmwareLoader();

  /// Loads raw firmware bytes from the given [firmwareType].
  ///
  /// [uri] is the asset path or HTTP URL and is required for every source
  /// except [FirmwareType.filepicker]. Returns an empty [Uint8List] when the
  /// user cancels the file picker without selecting a file.
  Future<Uint8List> loadFirmware(FirmwareType firmwareType, String? uri) async {
    switch (firmwareType) {
      case FirmwareType.assets:
        return loadBytesFromAsset(uri!);
      case FirmwareType.filepicker:
        return await pickFirmwareBytes() ?? Uint8List(0);
      case FirmwareType.url:
        return downloadBytesFromUrl(uri!);
    }
  }

  /// Splits [bytes] into fixed-size chunks for ESP-IDF BLE transfer.
  List<Uint8List> chunkFirmware(List<int> bytes, int chunkSize) {
    final List<Uint8List> chunks = [];
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final int end = i + chunkSize < bytes.length
          ? i + chunkSize
          : bytes.length;
      chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return chunks;
  }

  Future<Uint8List> loadBytesFromAsset(String filePath) async {
    final ByteData fileData = await rootBundle.load(filePath);
    return Uint8List.fromList(fileData.buffer.asUint8List());
  }

  Future<Uint8List> downloadBytesFromUrl(String url) async {
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

  Future<Uint8List?> pickFirmwareBytes() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      otaLogger.w('No firmware file selected');
      return null;
    }

    final file = result.files.first;
    otaLogger.d('Selected firmware file: ${file.name}');
    try {
      return Uint8List.fromList(await File(file.path!).readAsBytes());
    } on OtaException {
      rethrow;
    } catch (e) {
      throw OtaException('Error getting firmware data', e);
    }
  }
}
