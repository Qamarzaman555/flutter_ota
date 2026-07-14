import 'package:flutter_ota/src/exceptions/ota_exceptions.dart';
import 'package:flutter_ota/src/models/constants.dart';

/// Independent optional integrity features for an OTA session.
///
/// Combine freely — the device (and app) may support any subset:
/// * SHA-256 before transfer only
/// * SHA-256 after flash only
/// * CRC16 on packets only
/// * SHA without CRC, CRC without SHA, both, or neither
enum IntegrityFeature {
  /// App computes SHA-256 of the loaded binary and compares it to
  /// [FirmwareIntegrityConfig.expectedSha256] before any BLE write.
  ///
  /// Requires no device support — verification is entirely on the Flutter side.
  shaBeforeTransfer,

  /// Append a CRC-16 (Modbus) to each BLE data packet. If the firmware detects a
  /// CRC error it NACKs that packet (`0xF0`); the app retransmits only that
  /// packet (up to [FirmwareIntegrityConfig.maxPacketRetries]).
  ///
  /// Requires firmware that understands CRC-framed packets and NACK.
  packetCrc16,

  /// After the binary is written to flash, the firmware computes SHA-256 and
  /// reports match/mismatch. The app treats the update as successful only after
  /// a positive acknowledgment (and fails on a hash-mismatch opcode/status).
  ///
  /// Requires firmware that verifies flash contents against the expected hash
  /// sent during the session.
  shaAfterFlash,
}

/// Optional firmware integrity settings for an OTA update.
///
/// Defaults to [none] (no integrity features) so existing firmware keeps
/// working unchanged. Enable only the features your device firmware supports.
///
/// ```dart
/// // Server-provided hash, verify on the phone before transfer starts:
/// FirmwareIntegrityConfig(
///   features: {IntegrityFeature.shaBeforeTransfer},
///   expectedSha256Hex: 'a3f5…', // 64 hex chars
/// )
///
/// // Full path: pre-check + per-packet CRC + post-flash verify:
/// FirmwareIntegrityConfig(
///   features: {
///     IntegrityFeature.shaBeforeTransfer,
///     IntegrityFeature.packetCrc16,
///     IntegrityFeature.shaAfterFlash,
///   },
///   expectedSha256Hex: 'a3f5…',
/// )
/// ```
class FirmwareIntegrityConfig {
  /// Creates an integrity configuration.
  ///
  /// Provide the expected hash as either [expectedSha256Hex] (64 hex characters)
  /// or [expectedSha256Bytes] (exactly [sha256DigestSize] bytes). Required when
  /// any SHA feature is enabled.
  const FirmwareIntegrityConfig({
    this.features = const <IntegrityFeature>{},
    this.expectedSha256Hex,
    this.expectedSha256Bytes,
    this.maxPacketRetries = 3,
  });

  /// No integrity features — wire format matches prior behaviour when integrity
  /// is omitted.
  static const FirmwareIntegrityConfig none = FirmwareIntegrityConfig();

  /// Enabled integrity features for this session.
  final Set<IntegrityFeature> features;

  /// Expected SHA-256 digest as a lowercase/uppercase hex string (64 chars).
  final String? expectedSha256Hex;

  /// Expected SHA-256 digest as raw bytes ([sha256DigestSize] bytes).
  final List<int>? expectedSha256Bytes;

  /// Maximum retransmissions of a single CRC-NACK'd packet before failing.
  final int maxPacketRetries;

  /// Whether [IntegrityFeature.shaBeforeTransfer] is enabled.
  bool get verifyBeforeTransfer =>
      features.contains(IntegrityFeature.shaBeforeTransfer);

  /// Whether [IntegrityFeature.packetCrc16] is enabled.
  bool get packetCrc16 => features.contains(IntegrityFeature.packetCrc16);

  /// Whether [IntegrityFeature.shaAfterFlash] is enabled.
  bool get verifyAfterFlash =>
      features.contains(IntegrityFeature.shaAfterFlash);

  /// Whether any feature that needs device firmware support is enabled.
  bool get requiresDeviceSupport => packetCrc16 || verifyAfterFlash;

  /// Whether any SHA feature is enabled (and thus an expected digest is needed).
  bool get requiresExpectedSha256 => verifyBeforeTransfer || verifyAfterFlash;

  /// Parsed expected SHA-256 digest, or `null` when none was configured.
  List<int>? get resolvedExpectedSha256 {
    if (expectedSha256Bytes != null) {
      return List<int>.unmodifiable(expectedSha256Bytes!);
    }
    if (expectedSha256Hex != null) {
      return _parseHexSha256(expectedSha256Hex!);
    }
    return null;
  }

  /// Extra bytes appended to each data packet when [packetCrc16] is on.
  int get packetCrcOverhead => packetCrc16 ? crc16Size : 0;

  /// Validates this config and throws [OtaException] when inconsistent.
  void validate() {
    if (maxPacketRetries < 1) {
      throw OtaException(
        'maxPacketRetries must be at least 1 (got $maxPacketRetries).',
      );
    }

    if (!requiresExpectedSha256) return;

    final List<int>? digest = resolvedExpectedSha256;
    if (digest == null) {
      throw OtaException(
        'expectedSha256Hex or expectedSha256Bytes is required when '
        'shaBeforeTransfer or shaAfterFlash is enabled.',
      );
    }
    if (digest.length != sha256DigestSize) {
      throw OtaException(
        'Expected SHA-256 digest must be $sha256DigestSize bytes '
        '(got ${digest.length}).',
      );
    }
  }

  static List<int> _parseHexSha256(String hex) {
    final String normalized = hex.trim().toLowerCase().replaceAll(
      RegExp(r'[^0-9a-f]'),
      '',
    );
    if (normalized.length != sha256DigestSize * 2) {
      throw OtaException(
        'expectedSha256Hex must be ${sha256DigestSize * 2} hex characters '
        '(got ${normalized.length} after normalization).',
      );
    }

    final List<int> bytes = List<int>.filled(sha256DigestSize, 0);
    for (int i = 0; i < sha256DigestSize; i++) {
      bytes[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
