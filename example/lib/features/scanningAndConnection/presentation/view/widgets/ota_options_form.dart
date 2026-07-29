import 'package:flutter/material.dart';
import 'package:flutter_ota/flutter_ota.dart';
import 'package:ota_new_protocol/utils/colors.dart';

import '../../ota_integrity_mode.dart';

class OtaOptionsForm extends StatelessWidget {
  const OtaOptionsForm({
    super.key,
    required this.updateType,
    required this.firmwareType,
    required this.integrityMode,
    required this.urlController,
    required this.shaController,
    required this.onUpdateTypeChanged,
    required this.onFirmwareTypeChanged,
    required this.onIntegrityModeChanged,
  });

  final UpdateType updateType;
  final FirmwareType firmwareType;
  final OtaIntegrityMode integrityMode;
  final TextEditingController urlController;
  final TextEditingController shaController;
  final ValueChanged<UpdateType> onUpdateTypeChanged;
  final ValueChanged<FirmwareType> onFirmwareTypeChanged;
  final ValueChanged<OtaIntegrityMode> onIntegrityModeChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Module type'),
        const SizedBox(height: 8),
        SegmentedButton<UpdateType>(
          segments: const [
            ButtonSegment(
              value: UpdateType.espidf,
              label: Text('ESP-IDF'),
              icon: Icon(Icons.memory, size: 18),
            ),
            ButtonSegment(
              value: UpdateType.arduino,
              label: Text('Arduino'),
              icon: Icon(Icons.developer_board, size: 18),
            ),
          ],
          selected: {updateType},
          onSelectionChanged: (selection) {
            onUpdateTypeChanged(selection.first);
          },
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Firmware source'),
        const SizedBox(height: 8),
        SegmentedButton<FirmwareType>(
          segments: const [
            ButtonSegment(
              value: FirmwareType.filepicker,
              label: Text('File picker'),
              icon: Icon(Icons.folder_open, size: 18),
            ),
            ButtonSegment(
              value: FirmwareType.url,
              label: Text('URL'),
              icon: Icon(Icons.link, size: 18),
            ),
          ],
          selected: {firmwareType},
          onSelectionChanged: (selection) {
            onFirmwareTypeChanged(selection.first);
          },
        ),
        if (firmwareType == FirmwareType.url) ...[
          const SizedBox(height: 12),
          TextField(
            controller: urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Firmware URL',
              hintText: 'https://example.com/firmware.bin',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 24),
        const _SectionLabel('Integrity'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mode in OtaIntegrityMode.values)
              ChoiceChip(
                label: Text(_labelFor(mode)),
                selected: integrityMode == mode,
                selectedColor: secondaryColor.withValues(alpha: 0.25),
                onSelected: (_) => onIntegrityModeChanged(mode),
              ),
          ],
        ),
        if (integrityMode.needsSha) ...[
          const SizedBox(height: 12),
          TextField(
            controller: shaController,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Expected SHA-256 (hex)',
              hintText: '64 hex characters',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  static String _labelFor(OtaIntegrityMode mode) {
    return switch (mode) {
      OtaIntegrityMode.none => 'None',
      OtaIntegrityMode.preSha => 'Pre SHA',
      OtaIntegrityMode.postSha => 'Post SHA',
      OtaIntegrityMode.both => 'Both',
    };
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
