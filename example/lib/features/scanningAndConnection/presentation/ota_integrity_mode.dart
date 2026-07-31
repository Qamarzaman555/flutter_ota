import 'package:flutter_ota/flutter_ota.dart';

/// Integrity preset shown in the example UI.
enum OtaIntegrityMode { none, preSha, postSha, both }

extension OtaIntegrityModeX on OtaIntegrityMode {
  bool get needsSha => this != OtaIntegrityMode.none;

  FirmwareIntegrityConfig toConfig(String expectedSha256Hex) {
    final String hex = expectedSha256Hex.trim();
    return switch (this) {
      OtaIntegrityMode.none => FirmwareIntegrityConfig.none,
      OtaIntegrityMode.preSha => FirmwareIntegrityConfig(
        features: {IntegrityFeature.shaBeforeTransfer},
        expectedSha256Hex: hex,
      ),
      OtaIntegrityMode.postSha => FirmwareIntegrityConfig(
        features: {IntegrityFeature.shaAfterFlash},
        expectedSha256Hex: hex,
      ),
      OtaIntegrityMode.both => FirmwareIntegrityConfig(
        features: {
          IntegrityFeature.shaBeforeTransfer,
          IntegrityFeature.shaAfterFlash,
        },
        expectedSha256Hex: hex,
      ),
    };
  }
}

/// Returns a user-facing error, or `null` when the form is valid.
String? validateOtaForm({
  required FirmwareType firmwareType,
  required String url,
  required OtaIntegrityMode integrityMode,
  required String sha256Hex,
}) {
  if (firmwareType == FirmwareType.url) {
    if (url.trim().isEmpty) return 'Enter a firmware URL';
  } else if (firmwareType == FirmwareType.assets) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return 'Enter an asset path';
    if (!isSupportedFirmwareImage(trimmed)) {
      return 'Asset path must end with .bin or .img';
    }
  }
  if (integrityMode.needsSha && sha256Hex.trim().isEmpty) {
    return 'Enter the expected SHA-256 hex digest';
  }
  return null;
}
