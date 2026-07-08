/// Arduino ESP32 OTA service/characteristic UUIDs used by the example app.
abstract final class OtaBleConstants {
  static const String serviceUuid = 'd6f1d96d-594c-4c53-b1c6-144a1dfde6d8';
  static const String notifyCharacteristicUuid =
      '7ad671aa-21c0-46a4-b722-270e3ae3d830';
  static const String writeCharacteristicUuid =
      '23408888-1f40-4cd8-9b89-ca8d45f8a5b0';

  /// Chunk size requested for Arduino OTA writes (payload before 2-byte header).
  static const int arduinoMtuSize = 509;

  /// Preferred ATT MTU negotiation request on Android before OTA.
  static const int androidRequestedMtu = 500;

  /// Chunk size requested for ESP-IDF OTA writes (payload before 2-byte header).
  static const int espidfMtuSize = 509;
}
