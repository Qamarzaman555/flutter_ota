import 'package:flutter/material.dart';
import 'package:flutter_ota/flutter_ota.dart';
import 'package:get/get.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/controller/ota_update_controller.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/view/widgets/ota_options_form.dart';

import '../../../../common/custom_button/primary_action_button.dart';

class NewOTAUpdatePage extends GetView<OtaUpdateController> {
  const NewOTAUpdatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await controller.disconnectAndLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('OTA Update')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Connected Device Name: ${controller.deviceName}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Connected Device Mac: ${controller.deviceMac}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                Obx(
                  () => OtaOptionsForm(
                    updateType: UpdateType.espidf,
                    firmwareType: controller.firmwareType.value,
                    integrityMode: controller.integrityMode.value,
                    urlController: controller.urlController,
                    shaController: controller.shaController,
                    onUpdateTypeChanged: controller.setUpdateType,
                    onFirmwareTypeChanged: controller.setFirmwareType,
                    onIntegrityModeChanged: controller.setIntegrityMode,
                  ),
                ),
                const SizedBox(height: 32),
                PrimaryActionButton(
                  label: 'Start OTA',
                  onTap: controller.startOta,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
