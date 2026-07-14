/// CRC-16/IBM (Modbus) — poly 0xA001, init 0xFFFF, little-endian input.
///
/// Used when [IntegrityFeature.packetCrc16] is enabled. Firmware must use the
/// same polynomial and initial value when validating packets.
int crc16Modbus(List<int> data) {
  int crc = 0xFFFF;
  for (final int byte in data) {
    crc ^= byte & 0xFF;
    for (int bit = 0; bit < 8; bit++) {
      if ((crc & 0x0001) != 0) {
        crc = (crc >> 1) ^ 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc & 0xFFFF;
}

/// Appends a big-endian CRC-16 (Modbus) to [payload] and returns a new buffer.
///
/// CRC is computed over [payload] only.
List<int> appendCrc16(List<int> payload) {
  final int crc = crc16Modbus(payload);
  return <int>[...payload, (crc >> 8) & 0xFF, crc & 0xFF];
}
