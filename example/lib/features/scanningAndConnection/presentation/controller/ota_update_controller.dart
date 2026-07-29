import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ota/flutter_ota.dart';
import 'package:get/get.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/controller/scanning_connection_controller.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/ota_ble_constants.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/ota_ble_helpers.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/ota_integrity_mode.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/view/widgets/ota_progress_dialog.dart';
import 'package:ota_new_protocol/routing/routes.dart';

import '../../../../common/toast/show_toast.dart';

class OtaUpdateController extends GetxController {
  OtaUpdateController({HomePageController? home})
    : home = home ?? Get.find<HomePageController>();

  final HomePageController home;

  final Rx<UpdateType> updateType = UpdateType.espidf.obs;
  final Rx<FirmwareType> firmwareType = FirmwareType.filepicker.obs;
  final Rx<OtaIntegrityMode> integrityMode = OtaIntegrityMode.none.obs;

  late final TextEditingController urlController;
  late final TextEditingController shaController;

  Esp32OtaPackage? activePackage;
  bool showProgressDialog = false;

  bool _otaInProgress = false;
  bool _leavingOnDisconnect = false;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  BluetoothDevice? get device => home.gBleDevice;

  String get deviceName {
    final BluetoothDevice? current = device;
    if (current == null || current.platformName.isEmpty) return 'Unknown';
    return current.platformName;
  }

  String get deviceMac => device?.remoteId.str ?? 'Unknown';

  @override
  void onInit() {
    super.onInit();
    urlController = TextEditingController();
    shaController = TextEditingController(
      text: '737c55dada54fcbea9dd1b032ca450df1e6a21cdf3bc27045210b8d8622848cb',
    );
    _connectionSubscription = device?.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        returnToHomeOnDisconnect();
      }
    });
  }

  @override
  void onClose() {
    _connectionSubscription?.cancel();
    urlController.dispose();
    shaController.dispose();
    activePackage = null;
    super.onClose();
  }

  void setUpdateType(UpdateType type) => updateType.value = type;

  void setFirmwareType(FirmwareType type) => firmwareType.value = type;

  void setIntegrityMode(OtaIntegrityMode mode) => integrityMode.value = mode;

  void returnToHomeOnDisconnect() {
    if (_leavingOnDisconnect) return;
    _leavingOnDisconnect = true;
    home.gIsDeviceConnected.value = false;
    showProgressDialog = false;
    Get.offAllNamed(AppRoutes.splash);
    showToast('Device disconnected. Reconnect to start OTA again.');
  }

  Future<void> disconnectAndLeave() async {
    if (_leavingOnDisconnect) return;
    _leavingOnDisconnect = true;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    showProgressDialog = false;
    await home.clearLastDevice();
    await home.disconnectDevice();
    Get.offAllNamed(AppRoutes.splash);
  }

  void dismissProgressDialog({String? toast, bool force = false}) {
    if (!showProgressDialog && !force) return;
    showProgressDialog = false;
    if (Get.isDialogOpen ?? false) {
      Get.back<void>();
    }
    if (toast != null) showToast(toast);
  }

  void onProgressOutcome(OtaProgressOutcome outcome) {
    final String toast = switch (outcome) {
      OtaProgressOutcome.complete => 'OTA Update Complete',
      OtaProgressOutcome.failed =>
        'OTA Update Failed. Reconnect to the device before retrying.',
      OtaProgressOutcome.cancelled => 'OTA Update Cancelled',
    };
    dismissProgressDialog(toast: toast);
  }

  Future<void> cancelOta() async {
    final Esp32OtaPackage? package = activePackage;
    final bool wasInProgress = package?.isUpdating ?? false;
    dismissProgressDialog(
      toast: wasInProgress ? 'OTA Update Cancelled' : null,
      force: true,
    );
    try {
      await package?.cancelUpdate();
    } catch (e) {
      debugPrint('Error cancelling OTA: $e');
    }
  }

  Future<void> startOta() async {
    if (_otaInProgress) return;

    final String? validationError = validateOtaForm(
      firmwareType: firmwareType.value,
      url: urlController.text,
      integrityMode: integrityMode.value,
      sha256Hex: shaController.text,
    );
    if (validationError != null) {
      showToast(validationError);
      return;
    }

    final BluetoothDevice? currentDevice = device;
    final List<BluetoothService> services = home.gBleServices;
    if (currentDevice == null || services.isEmpty) {
      showToast('Connect to device first');
      return;
    }

    final characteristics = findOtaCharacteristics(services);
    if (characteristics == null) {
      await _showIncompatibleDeviceDialog();
      return;
    }

    _otaInProgress = true;
    try {
      await prepareOtaMtu(currentDevice);
      final Esp32OtaPackage otaPackage = Esp32OtaPackage(
        characteristics.notify,
        characteristics.write,
      );
      activePackage = otaPackage;

      showProgressDialog = true;
      Get.dialog<void>(
        OtaProgressDialog(
          otaPackage: otaPackage,
          isShowing: () => showProgressDialog,
          onOutcome: onProgressOutcome,
          onCancel: cancelOta,
        ),
        barrierDismissible: false,
      );

      otaVerboseLogging = true;
      final int mtuSize = updateType.value == UpdateType.arduino
          ? OtaBleConstants.arduinoMtuSize
          : OtaBleConstants.espidfMtuSize;
      await otaPackage.updateFirmware(
        currentDevice,
        updateType.value,
        firmwareType.value,
        uri: firmwareType.value == FirmwareType.url
            ? urlController.text.trim()
            : null,
        mtuSize: mtuSize,
        integrity: integrityMode.value.toConfig(shaController.text),
      );
      // await otaPackage.updateFirmware(
      //   currentDevice,
      //   UpdateType.espidf,
      //   FirmwareType.filepicker,
      //   mtuSize: mtuSize,
      //   integrity: FirmwareIntegrityConfig(
      //     features: {
      //       IntegrityFeature.shaBeforeTransfer,
      //       IntegrityFeature.shaAfterFlash,
      //     },
      //     expectedSha256Hex:
      //         '5e00d6e700e91e3598277b5b78fb32036d4098bbcad25ee566752a43a7f38f62',
      //   ),
      // );
    } on OtaException catch (e) {
      debugPrint('OTA failed: $e');
      dismissProgressDialog(toast: e.message);
    } catch (e) {
      debugPrint('Unexpected OTA error: $e');
      dismissProgressDialog(toast: 'OTA update failed');
    } finally {
      _otaInProgress = false;
    }
  }

  Future<void> _showIncompatibleDeviceDialog() async {
    await Get.dialog<void>(
      AlertDialog(
        title: const Text('Device Not Compatible'),
        content: const Text(
          'The device does not have the required characteristics for OTA firmware update.',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<void>(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
