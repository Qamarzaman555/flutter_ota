import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ota/flutter_ota.dart';
import 'package:get/get.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/controller/scanning_connection_controller.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/ota_ble_constants.dart';
import 'package:ota_new_protocol/routing/routes.dart';

import '../../../../common/custom_button/primary_action_button.dart';
import '../../../../common/toast/show_toast.dart';

class NewOTAUpdatePage extends StatefulWidget {
  const NewOTAUpdatePage({super.key});

  @override
  State<NewOTAUpdatePage> createState() => _NewOTAUpdatePageState();
}

class _NewOTAUpdatePageState extends State<NewOTAUpdatePage> {
  final HomePageController _controller = Get.find();

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  bool _leavingOnDisconnect = false;
  bool _otaInProgress = false;

  @override
  void initState() {
    super.initState();
    // Leave this screen if the device drops (cancel, dropout, or post-OTA reboot).
    final BluetoothDevice? device = _controller.gBleDevice;
    _connectionSubscription = device?.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _returnToHomeOnDisconnect();
      }
    });
  }

  void _returnToHomeOnDisconnect() {
    if (_leavingOnDisconnect || !mounted) return;
    _leavingOnDisconnect = true;

    _controller.gIsDeviceConnected.value = false;
    _controller.showProgressDialog = false;

    Get.offAllNamed(AppRoutes.splash);
    showToast('Device disconnected. Reconnect to start OTA again.');
  }

  /// Disconnects, clears the saved device (disables auto-reconnect), then goes home.
  Future<void> _disconnectAndLeave() async {
    if (_leavingOnDisconnect) return;
    // Prevent the connectionState listener from navigating a second time.
    _leavingOnDisconnect = true;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    _controller.showProgressDialog = false;
    await _controller.clearLastDevice();
    await _controller.disconnectDevice();

    if (!mounted) return;
    Get.offAllNamed(AppRoutes.splash);
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  ({BluetoothCharacteristic notify, BluetoothCharacteristic write})?
  _findOtaCharacteristics(List<BluetoothService> services) {
    for (final service in services) {
      if (service.uuid.toString() != OtaBleConstants.serviceUuid) continue;

      BluetoothCharacteristic? notify;
      BluetoothCharacteristic? write;
      for (final characteristic in service.characteristics) {
        final String uuid = characteristic.uuid.toString();
        if (uuid == OtaBleConstants.notifyCharacteristicUuid) {
          notify = characteristic;
        } else if (uuid == OtaBleConstants.writeCharacteristicUuid) {
          write = characteristic;
        }
      }

      if (notify != null && write != null) {
        return (notify: notify, write: write);
      }
    }
    return null;
  }

  Future<void> _prepareMtu(BluetoothDevice device) async {
    if (Platform.isAndroid) {
      await device.requestMtu(OtaBleConstants.androidRequestedMtu);
    }
  }

  void _dismissProgressDialog({String? toast, bool force = false}) {
    if (!mounted) return;
    if (!_controller.showProgressDialog && !force) return;
    _controller.showProgressDialog = false;
    // Always pop via the page navigator so Cancel still works after a
    // failed/cancelled terminal event (cancelUpdate is then a no-op).
    Navigator.of(context, rootNavigator: true).maybePop();
    if (toast != null) {
      showToast(toast);
    }
  }

  Widget _buildProgressDialog(Esp32OtaPackage otaPackage) {
    return AlertDialog(
      title: const Text('OTA Update in Progress'),
      content: StreamBuilder<int>(
        stream: otaPackage.percentageStream,
        initialData: 0,
        builder: (dialogContext, snapshot) {
          final int value = snapshot.data ?? 0;

          if ((value == cancelledValue || value == failedValue) &&
              _controller.showProgressDialog) {
            final bool failed = value == failedValue;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _dismissProgressDialog(
                toast: failed
                    ? 'OTA Update Failed. Reconnect to the device before retrying.'
                    : 'OTA Update Cancelled',
              );
            });
            return const LinearProgressIndicator(value: 0);
          }

          final double progress = (value.clamp(0, 100)) / 100.0;
          if (progress >= 1.0 && _controller.showProgressDialog) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _dismissProgressDialog(toast: 'OTA Update Complete');
            });
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: progress,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                backgroundColor: Colors.grey[300],
              ),
              const SizedBox(height: 8),
              Text('${(progress * 100).round()}%'),
            ],
          );
        },
      ),
      actions: [
        PrimaryActionButton(
          label: 'Cancel',
          onTap: () async {
            // After a terminal failure, isUpdating is already false and
            // cancelUpdate is a no-op — still close the dialog from here.
            final bool wasInProgress = otaPackage.isUpdating;
            try {
              await otaPackage.cancelUpdate();
            } catch (e) {
              debugPrint('Error cancelling OTA: $e');
            }
            _dismissProgressDialog(
              toast: wasInProgress ? 'OTA Update Cancelled' : null,
              force: true,
            );
            // Cancelling leaves the ESP32 mid-OTA; reconnect before retrying.
          },
        ),
      ],
    );
  }

  Future<void> _showIncompatibleDeviceDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Not Compatible'),
        content: const Text(
          'The device does not have the required characteristics for OTA firmware update.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _startOta() async {
    if (_otaInProgress) return;

    final BluetoothDevice? device = _controller.gBleDevice;
    final List<BluetoothService> services = _controller.gBleServices;

    if (device == null || services.isEmpty) {
      showToast('Connect to device first');
      return;
    }

    final characteristics = _findOtaCharacteristics(services);
    if (characteristics == null) {
      await _showIncompatibleDeviceDialog();
      return;
    }

    _otaInProgress = true;
    try {
      await _prepareMtu(device);

      final Esp32OtaPackage otaPackage = Esp32OtaPackage(
        characteristics.notify,
        characteristics.write,
      );

      _controller.showProgressDialog = true;
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _buildProgressDialog(otaPackage),
      );
      otaVerboseLogging = true;
      await otaPackage.updateFirmware(
        device,
        UpdateType.espidf,
        FirmwareType.url,
        uri:
            'https://firebasestorage.googleapis.com/v0/b/liion-power-app.appspot.com/o/Internal%20fw%2FRelease_v1.7.1.img?alt=media&token=f2f814df-7ee7-4374-9a15-556d82655953',
        mtuSize: OtaBleConstants.arduinoMtuSize,
      );
    } on OtaException catch (e) {
      debugPrint('OTA failed: $e');
      _dismissProgressDialog(toast: e.message);
    } catch (e) {
      debugPrint('Unexpected OTA error: $e');
      _dismissProgressDialog(toast: 'OTA update failed');
    } finally {
      _otaInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final BluetoothDevice? device = _controller.gBleDevice;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _disconnectAndLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('OTA Update')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Connected Device Name: ${device?.platformName ?? 'Unknown'}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Connected Device Mac: ${device?.remoteId ?? 'Unknown'}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                PrimaryActionButton(label: 'Start OTA', onTap: _startOta),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
