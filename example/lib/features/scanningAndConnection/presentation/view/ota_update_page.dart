import 'dart:async';
import 'dart:io';
import 'package:flutter_ota/ota_package.dart';
import 'package:flutter/material.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/controller/scanning_connection_controller.dart';
import 'package:ota_new_protocol/routing/routes.dart';
import 'package:get/get.dart';
import '../../../../common/custom_button/feedback_enabled_button.dart';
import '../../../../common/toast/show_toast.dart';
import '../../../../utils/colors.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class NewOTAUpdatePage extends StatefulWidget {
  const NewOTAUpdatePage({super.key});

  @override
  State<NewOTAUpdatePage> createState() => _NewOTAUpdatePageState();
}

class _NewOTAUpdatePageState extends State<NewOTAUpdatePage> {
  HomePageController homePageController = Get.find();

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  bool _leavingOnDisconnect = false;

  @override
  void initState() {
    super.initState();
    // If the device disconnects (after a cancel, a dropout, or a reboot once the
    // OTA finishes) leave this screen and return to the app's home screen.
    final BluetoothDevice? device = homePageController.gBleDevice;
    _connectionSubscription = device?.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _returnToHomeOnDisconnect();
      }
    });
  }

  void _returnToHomeOnDisconnect() {
    if (_leavingOnDisconnect || !mounted) return;
    _leavingOnDisconnect = true;

    homePageController.gIsDeviceConnected.value = false;
    // Stop the progress dialog from trying to dismiss itself after we navigate.
    homePageController.showProgressDialog = false;

    // Clear the navigation stack back to the home ("Flutter OTA App") screen.
    Get.offAllNamed(AppRoutes.splash);
    showToast('Device disconnected. Reconnect to start OTA again.');
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("OTA Update")),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            "Connected Device Name: ${homePageController.gBleDevice!.platformName}",
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              "Connected Device Mac: ${homePageController.gBleDevice!.remoteId}",
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: FeedbackEnabledButton(
                scaleFactor: 1.0,
                translationFactorX: 0.0,
                childWidget: Container(
                  //height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.rectangle,
                    border: Border.all(color: Colors.transparent, width: 2),
                    borderRadius: BorderRadius.circular(10.0),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [secondaryColor, secondaryColor],
                    ),
                  ),
                  //margin: const EdgeInsets.only(top: 10.0),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "Start OTA",
                          style: TextStyle(
                            color: Color(0xFFFFFFFF),
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                onTap: () async {
                  print("OTA Update tapped");
                  // Call the OTA update logic here
                  BluetoothDevice? device = homePageController.gBleDevice;
                  List<BluetoothService> services =
                      homePageController.gBleServices;

                  if (device == null || services.isEmpty) {
                    showToast("Connect to device first");
                    print("Device or services not available for OTA update");
                    return;
                  }

                  bool characteristicsFound = false;

                  for (BluetoothService service in services) {
                    print(
                      "In services loop and services lenght is ${services.length}",
                    );
                    if (service.uuid
                            .toString() == //'d6f1d96d-594c-4c53-b1c6-144a1dfde6d8') {
                        'd6f1d96d-594c-4c53-b1c6-144a1dfde6d8') {
                      //arduino uuid
                      print("service found");
                      final characteristics = service.characteristics;
                      BluetoothCharacteristic? notifyUuid;
                      BluetoothCharacteristic? writeUuid;

                      for (BluetoothCharacteristic c in characteristics) {
                        if (c.uuid
                                .toString() == //'7ad671aa-21c0-46a4-b722-270e3ae3d830') {
                            '7ad671aa-21c0-46a4-b722-270e3ae3d830') {
                          // arduino
                          notifyUuid = c;
                        }
                        if (c.uuid
                                .toString() == //'23408888-1f40-4cd8-9b89-ca8d45f8a5b0') {
                            '23408888-1f40-4cd8-9b89-ca8d45f8a5b0') {
                          //arduino
                          writeUuid = c;
                        }
                      }

                      if (notifyUuid != null && writeUuid != null) {
                        if (Platform.isAndroid) {
                          print("Plateform is andriod");
                          // Request a new MTU size for Android
                          const newMtu = 500;
                          await device.requestMtu(newMtu);

                          // The MTU request was successful, print the new MTU size
                          print('New MTU size (Android): $newMtu');
                        } else if (Platform.isIOS) {
                          // Use fixed MTU size of 185 for iOS
                          const newMtu = 185;
                          print('New MTU size (iOS): $newMtu');
                        }

                        Esp32OtaPackage esp32otaPackage = Esp32OtaPackage(
                          notifyUuid,
                          writeUuid,
                        );

                        print("After package data set");

                        // Show the progress dialog
                        // ignore_for_file: use_build_context_synchronously
                        homePageController.showProgressDialog = true;
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (context) => AlertDialog(
                            title: const Text('OTA Update in Progress'),
                            content: StreamBuilder<int>(
                              stream: esp32otaPackage.percentageStream,
                              initialData: 0,
                              builder: (BuildContext context, AsyncSnapshot<int> snapshot) {
                                final int value = snapshot.data ?? 0;

                                // The package emits cancelledValue (-1)
                                // when the update is cancelled and
                                // failedValue (-2) when it fails because of
                                // a BLE error (disconnect, GATT 133, etc.).
                                if ((value == cancelledValue ||
                                        value == failedValue) &&
                                    homePageController.showProgressDialog) {
                                  final bool failed = value == failedValue;
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (!mounted ||
                                        !homePageController
                                            .showProgressDialog) {
                                      return;
                                    }
                                    homePageController.showProgressDialog =
                                        false;
                                    Navigator.of(context).pop();
                                    showToast(
                                      failed
                                          ? 'OTA Update Failed. Reconnect to the device before retrying.'
                                          : 'OTA Update Cancelled',
                                    );
                                  });
                                  return const LinearProgressIndicator(
                                    value: 0,
                                  );
                                }

                                double progress = value / 100.toDouble();
                                if (progress >= 1.0 &&
                                    homePageController.showProgressDialog) {
                                  // Dismiss the progress dialog when the OTA update is complete.
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (!mounted ||
                                        !homePageController
                                            .showProgressDialog) {
                                      return;
                                    }
                                    homePageController.showProgressDialog =
                                        false;
                                    Navigator.of(context).pop();
                                    // Use Get.snackbar (showToast), not
                                    // ScaffoldMessenger — dialog context has
                                    // no Scaffold ancestor.
                                    showToast('OTA Update Complete');
                                  });
                                }
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    LinearProgressIndicator(
                                      value: progress,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                            Colors.blue,
                                          ),
                                      backgroundColor: Colors.grey[300],
                                    ),
                                    const SizedBox(height: 8),
                                    Text('${(progress * 100).round()}%'),
                                  ],
                                );
                              },
                            ),
                            actions: [
                              FeedbackEnabledButton(
                                scaleFactor: 1.0,
                                translationFactorX: 0.0,
                                childWidget: Container(
                                  //height: 30,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.rectangle,
                                    border: Border.all(
                                      color: Colors.transparent,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.circular(10.0),
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [secondaryColor, secondaryColor],
                                    ),
                                  ),
                                  //margin: const EdgeInsets.only(top: 10.0),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 20,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          "Cancel",
                                          style: TextStyle(
                                            color: Color(0xFFFFFFFF),
                                            fontFamily: 'Inter',
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                onTap: () async {
                                  await esp32otaPackage.cancelUpdate();
                                  // Cancelling leaves the ESP32 mid-OTA. The
                                  // device must be reconnected before another
                                  // OTA can be started on a clean session.
                                },
                              ),
                            ],
                          ),
                        );

                        // Perform the OTA update with the picked binfile
                        await esp32otaPackage.updateFirmware(
                          device,
                          UpdateType.espidf, //Update Type
                          FirmwareType.url,
                          service,
                          notifyUuid,
                          writeUuid,
                          // binFilePath: "assets/Release_v1.5.23-rc4.img",
                          url:
                              'https://firebasestorage.googleapis.com/v0/b/liion-power-app.appspot.com/o/Internal%20fw%2FRelease_v1.7.1.img?alt=media&token=f2f814df-7ee7-4374-9a15-556d82655953',
                        );
                        /*if (binfile != null) {
                              await esp32otaPackage.updateFirmware(
                                device,
                                1,
                                service,
                                dataUuid,
                                controlUuid,
                                binFilePath: "assets/helllo.ino.bin",
                              );
                            }*/

                        // Initialize BleUartController before sending a command
                        // bleUartController.init();

                        characteristicsFound =
                            true; // Set the flag to true since characteristics were found
                        break; // Exit the loop since characteristics were found
                      }
                    }
                  }

                  if (!characteristicsFound) {
                    // Display a dialog indicating that the device isn't compatible for the firmware update
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Device Not Compatible'),
                        content: const Text(
                          'The device does not have the required characteristics for OTA firmware update.',
                        ),
                        actions: [
                          ElevatedButton(
                            onPressed: () async {
                              Navigator.pop(context);
                            },
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
