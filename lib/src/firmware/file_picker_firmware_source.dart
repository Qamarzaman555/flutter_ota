import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:flutter_ota/src/core/firmware_source.dart';
import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/logging/ota_logger.dart';

/// Loads firmware from a user-selected file via the platform file picker.
class FilePickerFirmwareSource implements FirmwareSource {
  @override
  Future<Uint8List> load() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      otaLogger.w('No firmware file selected');
      return Uint8List(0);
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
