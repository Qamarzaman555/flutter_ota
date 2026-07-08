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
