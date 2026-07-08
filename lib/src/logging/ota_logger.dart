import 'package:logger/logger.dart';

/// Shared logger for the OTA package.
///
/// Uses [PrettyPrinter] to emit colorized, level-tagged logs (with emojis) so
/// the BLE/OTA flow is easy to follow during development. In release builds the
/// default [DevelopmentFilter] suppresses output, so these logs do not ship to
/// production.
final Logger otaLogger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 6,
    lineLength: 90,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
  ),
);

/// When `true`, emits logs that include full firmware byte arrays and BLE
/// packet payloads. Off by default to reduce noise and avoid exposing binary
/// contents in development logs.
bool otaVerboseLogging = false;

void verboseTrace(String message) {
  if (otaVerboseLogging) {
    otaLogger.t(message);
  }
}

void verboseDebug(String message) {
  if (otaVerboseLogging) {
    otaLogger.d(message);
  }
}
