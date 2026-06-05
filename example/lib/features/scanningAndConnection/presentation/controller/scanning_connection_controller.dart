import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../../../common/toast/show_toast.dart';

class HomePageController extends GetxController {
  RxString selectedLeoDevice = "".obs;

  RxList<BluetoothDevice> scannedDevicesList = <BluetoothDevice>[].obs;
  RxDouble screenHeight = 0.0.obs;
  BluetoothDevice? gBleDevice;
  RxList<BluetoothService> gBleServices = <BluetoothService>[].obs;
  BluetoothCharacteristic? charRep;
  RxBool gIsDeviceConnected = false.obs;
  bool showProgressDialog = true;

  RxList<BluetoothDevice> connectedDevice = <BluetoothDevice>[].obs;

  StreamSubscription? streamSubscription;
  Future<void> scanningMethod() async {
    print("In scanning method");
    final isScanning = FlutterBluePlus.isScanningNow;
    if (isScanning) {
      await FlutterBluePlus.stopScan();
    }

    await FlutterBluePlus.stopScan();
    //Empty the Devices List before storing new value
    scannedDevicesList.value = [];

    await streamSubscription?.cancel();

    streamSubscription = FlutterBluePlus.scanResults.listen(
      (results) {
        for (ScanResult r in results) {
          if (r.device.localName.isNotEmpty &&
              !scannedDevicesList.contains(r.device)) {
            print("device name is ${r.device.localName}");
            scannedDevicesList.add(r.device);
            // Listen for changes in connection state
            r.device.connectionState.listen((connectionState) {
              if (connectionState == BluetoothConnectionState.connected) {
                // Remove the device from the list if it's connected
                scannedDevicesList.remove(r.device);
              }
            });
            /*if (r.device.toString().toLowerCase().contains("laser gun")) {
                print("device name is ${r.device.localName}");
                connectionController.devicesList.add(r.device);
              }*/
          }
        }
      },
    );

    await FlutterBluePlus.startScan();
  }

  Future<bool> connectToDevice() async {
    await FlutterBluePlus.stopScan();

    final device = gBleDevice;
    if (device == null) {
      showToast('No device selected');
      return false;
    }

    try {
      // Start from a clean state so a stale connection can't break discovery.
      if (device.isConnected) {
        await device.disconnect();
      }

      print("before trying to connect");
      await device.connect(autoConnect: false, license: License.nonprofit);
      print("after connect");

      // Negotiate a larger MTU before discovering services (Android only).
      if (Platform.isAndroid) {
        await device.requestMtu(200);
        print("mtu set");
      }

      // Only safe to discover services once the device is actually connected.
      gBleServices.assignAll(await device.discoverServices());
      print("Services discovered in connect is $gBleServices");

      gIsDeviceConnected.value = true;
      showToast('Connected');
      return true;
    } catch (e) {
      print("Connection failed: $e");
      gIsDeviceConnected.value = false;
      try {
        await device.disconnect();
      } catch (_) {
        // Ignore: device may already be disconnected.
      }
      showToast('Connection failed');
      return false;
    }
  }
}
