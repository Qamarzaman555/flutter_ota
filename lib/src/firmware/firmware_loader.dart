import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';

/// Loads firmware binaries from assets, the file picker, or HTTP URLs.
class FirmwareLoader {
  const FirmwareLoader();

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

  Future<List<Uint8List>> readChunkedBinaryFile(
    String filePath,
    int mtuSize,
  ) async {
    otaLogger.d('Reading binary firmware from asset path: $filePath');
    final Uint8List bytes = await loadBytesFromAsset(filePath);
    verboseTrace('Firmware bytes: $bytes');
    return chunkFirmware(bytes, mtuSize);
  }

  Future<List<Uint8List>> loadChunkedFromPicker(int mtuSize) async {
    otaLogger.d('Chunk size (MTU) in file picker: $mtuSize');

    final Uint8List? bytes = await pickFirmwareBytes();
    if (bytes == null) {
      return [];
    }

    if (bytes.isEmpty) {
      throw EmptyFirmwareException(
        'Empty firmware data. Please select a valid firmware file.',
      );
    }

    otaLogger.d('Dividing firmware data into chunks');
    return chunkFirmware(bytes, mtuSize);
  }

  Future<Uint8List> loadRawFromPicker() async {
    final Uint8List? bytes = await pickFirmwareBytes();
    if (bytes == null) {
      return Uint8List(0);
    }

    if (bytes.isEmpty) {
      throw EmptyFirmwareException(
        'Empty firmware data. Please select a valid firmware file.',
      );
    }

    return bytes;
  }

  Future<List<Uint8List>> loadChunkedFromUrl(String url, int mtuSize) async {
    final Uint8List bytes = await downloadBytesFromUrl(url);
    return chunkFirmware(bytes, mtuSize);
  }

  Future<Uint8List> loadRawFromUrl(String url) async {
    otaLogger.d('Downloading firmware (Arduino) from: $url');
    final Uint8List bytes = await downloadBytesFromUrl(url);
    otaLogger.d('Downloaded firmware length: ${bytes.length} bytes');
    return bytes;
  }
}
