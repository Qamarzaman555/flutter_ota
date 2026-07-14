/// Base class for all OTA-related errors thrown by this package.
///
/// Catch this to handle any failure originating from the OTA flow (firmware
/// loading, download, validation, etc.) in a type-safe way instead of matching
/// on raw [String] messages.
class OtaException implements Exception {
  OtaException(this.message, [this.cause]);

  /// Human-readable description of what went wrong.
  final String message;

  /// The underlying error that caused this exception, if any.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'OtaException: $message'
      : 'OtaException: $message ($cause)';
}

/// Thrown when a firmware source yields no data.
///
/// Examples: an empty asset/file, an empty HTTP response body, or no file
/// selected from the picker. Signals the caller to abort before any OTA writes
/// are sent to the device.
class EmptyFirmwareException extends OtaException {
  EmptyFirmwareException([
    super.message =
        'Firmware is empty. Please provide a valid, non-empty firmware binary.',
  ]);
}

/// Thrown when downloading firmware over HTTP fails (non-200 status, timeout,
/// or network error).
class FirmwareDownloadException extends OtaException {
  FirmwareDownloadException(String message, {this.statusCode, Object? cause})
    : super(message, cause);

  /// The HTTP status code, when the failure was an unsuccessful response.
  final int? statusCode;
}

/// Base class for firmware integrity verification failures.
class FirmwareIntegrityException extends OtaException {
  FirmwareIntegrityException(super.message, [super.cause]);
}

/// Thrown when a SHA-256 digest does not match the expected value.
///
/// Used for the app-side pre-transfer check ([IntegrityFeature.shaBeforeTransfer])
/// and when reporting a device-side post-flash mismatch that includes digests.
class FirmwareHashMismatchException extends FirmwareIntegrityException {
  FirmwareHashMismatchException({
    required this.phase,
    required this.expectedHex,
    required this.actualHex,
  }) : super(
         'Firmware SHA-256 mismatch during $phase. '
         'Expected $expectedHex, got $actualHex.',
       );

  /// `'before-transfer'` or `'after-flash'`.
  final String phase;

  /// Expected digest as lowercase hex.
  final String expectedHex;

  /// Actual digest as lowercase hex (when known).
  final String actualHex;
}

/// Thrown when the device reports a post-flash SHA-256 mismatch without
/// returning the computed digest bytes.
class DeviceHashMismatchException extends FirmwareIntegrityException {
  DeviceHashMismatchException([
    super.message =
        'Device reported a post-flash SHA-256 mismatch. '
        'The update will not be marked successful.',
  ]);
}

/// Thrown when a packet exceeds the CRC NACK retransmission limit.
class PacketCrcException extends FirmwareIntegrityException {
  PacketCrcException({
    required this.packetIndex,
    required this.attempts,
  }) : super(
         'Packet $packetIndex failed CRC verification after $attempts '
         'attempt(s).',
       );

  /// Zero-based index of the packet (within the current Arduino segment, or
  /// global chunk index for ESP-IDF).
  final int packetIndex;

  /// How many times the packet was transmitted (including the first send).
  final int attempts;
}
