import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_ota/src/core/ota_transport.dart';
import 'package:flutter_ota/src/transport/ble_repository.dart';

/// BLE implementation of [OtaTransport].
///
/// Maps the bulk data channel to [writeCharacteristic] and the control channel
/// to [notifyCharacteristic]. Inbound messages come from BLE notifications.
class BleOtaTransport implements OtaTransport {
  BleOtaTransport({
    required BluetoothDevice device,
    required BluetoothCharacteristic notifyCharacteristic,
    required BluetoothCharacteristic writeCharacteristic,
    BleRepository? bleRepository,
  }) : _device = device,
       _notifyCharacteristic = notifyCharacteristic,
       _writeCharacteristic = writeCharacteristic,
       _bleRepository = bleRepository ?? BleRepository();

  final BluetoothDevice _device;
  final BluetoothCharacteristic _notifyCharacteristic;
  final BluetoothCharacteristic _writeCharacteristic;
  final BleRepository _bleRepository;

  @override
  Future<void> prepare({required int mtuSize}) async {
    await _bleRepository.requestMtu(_device, mtuSize);
  }

  @override
  Future<void> writeData(Uint8List data) async {
    await _bleRepository.writeDataCharacteristic(_writeCharacteristic, data);
  }

  @override
  Future<void> writeControl(Uint8List data) async {
    await _bleRepository.writeDataCharacteristic(_notifyCharacteristic, data);
  }

  @override
  Future<Uint8List> readControl() async {
    final List<int> value = await _bleRepository.readCharacteristic(
      _notifyCharacteristic,
    );
    return Uint8List.fromList(value);
  }

  @override
  Future<void> startInbound() async {
    await _notifyCharacteristic.setNotifyValue(true);
  }

  @override
  Stream<Uint8List> get inbound =>
      _notifyCharacteristic.onValueReceived.map(Uint8List.fromList);

  @override
  Future<void> dispose() async {
    // BLE characteristics are owned by the caller; nothing to release here.
  }
}
