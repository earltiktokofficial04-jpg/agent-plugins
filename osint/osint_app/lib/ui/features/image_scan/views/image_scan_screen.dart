import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../../data/services/image_indicator_scanner.dart';
import '../../../core/scan_status.dart';
import '../../../core/widgets.dart';
import '../view_models/image_scan_view_model.dart';

/// What to do with an indicator the user picked.
enum ImageScanAction {
  /// Reputation across APIs and public blocklists.
  threatIntel,

  /// Infrastructure and attack-surface mapping. Domains only.
  recon,
}

/// Reads indicators out of a photo, screenshot or QR code.
class ImageScanScreen extends StatefulWidget {
  const ImageScanScreen({required this.onTargetChosen, super.key});

  /// Called when the user picks an indicator and what to do with it.
  final void Function(ExtractedTarget extracted, ImageScanAction action)
  onTargetChosen;

  @override
  State<ImageScanScreen> createState() => _ImageScanScreenState();
}

class _ImageScanScreenState extends State<ImageScanScreen> {
  @override
  void initState() {
    super.initState();
    // Warm the live TLD list so filenames are not mistaken for hostnames.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ImageScanViewModel>().loadTlds();
    });
  }

  static String _kindLabel(ExtractedTarget extracted) =>
      switch (extracted.target.kind) {
        TargetKind.domain => 'domain',
        TargetKind.url => 'URL',
        TargetKind.ipv4 => 'IPv4',
        TargetKind.ipv6 => 'IPv6',
        TargetKind.md5 => 'MD5',
        TargetKind.sha1 => 'SHA-1',
        TargetKind.sha256 => 'SHA-256',
        TargetKind.unknown => 'unknown',
      };

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ImageScanViewModel>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan from image'),
        actions: [
          if (viewModel.found.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: viewModel.clear,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: viewModel.isBusy
                      ? null
                      : () => viewModel.scanImage(ImageSource2.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: viewModel.isBusy
                      ? null
                      : () => viewModel.scanImage(ImageSource2.gallery),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Reads QR codes and text on the device. The image is never '
            'uploaded anywhere.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (viewModel.isBusy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (viewModel.status == ScanStatus.idle && viewModel.found.isEmpty)
            const EmptyState(
              icon: Icons.qr_code_scanner,
              message:
                  'Point the camera at a QR code, or pick a screenshot of a '
                  'report or email.\n\nEvery domain, address and hash found '
                  'in it becomes something you can look up.',
            ),
          if (viewModel.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                viewModel.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (viewModel.found.isNotEmpty) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Found',
              trailing: Text('${viewModel.found.length}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (viewModel.found.any((e) => e.wasDefanged))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Some indicators were written defanged — the source '
                        'already treats them as hostile.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  Text(
                    viewModel.usingLiveTlds
                        ? 'Checked against the live IANA TLD list.'
                        : 'Checked against the bundled TLD list — unusual '
                              'suffixes may be missed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            for (final extracted in viewModel.found)
              _IndicatorCard(
                extracted: extracted,
                kindLabel: _kindLabel(extracted),
                onChosen: (action) => widget.onTargetChosen(extracted, action),
              ),
          ],
          if (viewModel.found.isEmpty &&
              viewModel.readout != null &&
              viewModel.readout!.recognisedText.trim().isNotEmpty)
            SectionCard(
              title: 'Text that was read',
              child: SelectableText(
                viewModel.readout!.recognisedText,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One extracted indicator, with the evidence for what it was read from.
class _IndicatorCard extends StatelessWidget {
  const _IndicatorCard({
    required this.extracted,
    required this.kindLabel,
    required this.onChosen,
  });

  final ExtractedTarget extracted;
  final String kindLabel;
  final void Function(ImageScanAction action) onChosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showsRaw = extracted.raw != extracted.target.value;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  extracted.origin == TargetOrigin.code
                      ? Icons.qr_code
                      : Icons.text_fields,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  kindLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Spacer(),
                if (extracted.occurrences > 1)
                  Text(
                    '×${extracted.occurrences}',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              extracted.target.value,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (showsRaw)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'read as: ${extracted.raw}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            if (extracted.fromEmail)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'from an email address',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => onChosen(ImageScanAction.threatIntel),
                  child: const Text('Reputation'),
                ),
                // Recon maps a domain's infrastructure; it has nothing to say
                // about an address or a file hash.
                if (extracted.target.kind == TargetKind.domain ||
                    extracted.target.kind == TargetKind.url)
                  OutlinedButton(
                    onPressed: () => onChosen(ImageScanAction.recon),
                    child: const Text('Recon'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
