import 'package:flutter/services.dart';

import 'package:flutter_ota/src/core/firmware_source.dart';

/// Loads firmware from a bundled asset path.
class AssetFirmwareSource implements FirmwareSource {
  AssetFirmwareSource(this.path);

  final String path;

  @override
  Future<Uint8List> load() async {
    final ByteData fileData = await rootBundle.load(path);
    return Uint8List.fromList(fileData.buffer.asUint8List());
  }
}
