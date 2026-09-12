import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../core/scan_status.dart';
import '../../../core/widgets.dart';
import '../view_models/brand_view_model.dart';

/// Look-alike domain discovery for a brand.
class BrandScreen extends StatefulWidget {
  const BrandScreen({super.key});

  @override
  State<BrandScreen> createState() => _BrandScreenState();
}

class _BrandScreenState extends State<BrandScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<BrandViewModel>();
    final report = viewModel.report;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TargetField(
          controller: _controller,
          isBusy: viewModel.isBusy,
          label: 'Brand domain',
          onSubmit: () => viewModel.sweep(_controller.text),
        ),
        const SizedBox(height: 14),
        SegmentedButton<SweepMode>(
          segments: const [
            ButtonSegment(
              value: SweepMode.typosquat,
              label: Text('Typosquat'),
              icon: Icon(Icons.text_fields, size: 18),
            ),
            ButtonSegment(
              value: SweepMode.namespace,
              label: Text('Namespace'),
              icon: Icon(Icons.public, size: 18),
            ),
          ],
          selected: {viewModel.mode},
          onSelectionChanged: viewModel.isBusy
              ? null
              : (selection) => viewModel.setMode(selection.first),
        ),
        const SizedBox(height: 6),
        Text(
          viewModel.mode == SweepMode.typosquat
              ? 'Misspells the brand name and keeps the suffix: '
                  'exarnple.com, exampel.com.'
              : 'Keeps the brand name and varies the suffix: example.tk, '
                  'example.com.my. Namespace lists come from IANA and the '
                  'Public Suffix List.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        if (viewModel.mode == SweepMode.namespace) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<SweepBreadth>(
            initialValue: viewModel.breadth,
            decoration: const InputDecoration(
              labelText: 'Breadth',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: SweepBreadth.focused,
                child: Text('Focused — commonly abused TLDs'),
              ),
              DropdownMenuItem(
                value: SweepBreadth.allTlds,
                child: Text('All TLDs — every delegated TLD'),
              ),
              DropdownMenuItem(
                value: SweepBreadth.allSuffixes,
                child: Text('All suffixes — the full Public Suffix List'),
              ),
            ],
            onChanged: viewModel.isBusy
                ? null
                : (value) {
                    if (value != null) viewModel.setBreadth(value);
                  },
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Candidates to check: ${viewModel.limit}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: viewModel.limit.toDouble(),
          min: 25,
          max: 2000,
          divisions: 79,
          label: '${viewModel.limit}',
          onChanged: viewModel.isBusy
              ? null
              : (value) => viewModel.setLimit(value.round()),
        ),
        Text(
          'Each candidate costs one or two DNS lookups. Higher limits find '
          'more, and take longer on mobile data.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        if (viewModel.isBusy) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: viewModel.progress),
          const SizedBox(height: 6),
          Text(
            'Checked ${viewModel.checked} of ${viewModel.total}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (viewModel.status == ScanStatus.rejected)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              viewModel.rejection,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (viewModel.status == ScanStatus.idle)
          const EmptyState(
            icon: Icons.copy_all_outlined,
            message:
                'Generates look-alike domains for a brand, then checks which '
                'are actually registered.\n\nNo API key needed.',
          ),
        if (report != null && !viewModel.isBusy) ..._results(context, report),
      ],
    );
  }

  List<Widget> _results(BuildContext context, BrandReport report) {
    final theme = Theme.of(context);

    return [
      SectionCard(
        title: 'Sweep',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyValueRow(label: 'Brand', value: report.brandDomain),
            KeyValueRow(
              label: 'Generated',
              value: '${report.candidatesGenerated}',
            ),
            KeyValueRow(
              label: 'Checked',
              value: '${report.candidatesChecked}',
            ),
            KeyValueRow(label: 'Registered', value: '${report.findings.length}'),
            KeyValueRow(label: 'Actionable', value: '${report.actionable.length}'),
          ],
        ),
      ),
      if (report.findings.isEmpty)
        const SectionCard(
          title: 'Findings',
          child: Text('No registered look-alikes among the candidates checked.'),
        ),
      for (final finding in report.findings)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        finding.candidate.domain,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (finding.isActionable)
                      Chip(
                        label: const Text('Live'),
                        visualDensity: VisualDensity.compact,
                        backgroundColor:
                            theme.colorScheme.errorContainer,
                        labelStyle: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                KeyValueRow(
                  label: 'Technique',
                  value: finding.candidate.technique.name,
                ),
                if (finding.addresses.isNotEmpty)
                  KeyValueRow(
                    label: 'Resolves to',
                    value: finding.addresses.join(', '),
                  ),
                if (finding.nameservers.isNotEmpty)
                  KeyValueRow(
                    label: 'Nameservers',
                    value: finding.nameservers.join(', '),
                  ),
                KeyValueRow(
                  label: 'Accepts mail',
                  value: finding.hasMailExchanger ? 'yes' : 'no',
                ),
              ],
            ),
          ),
        ),
      SectionCard(
        title: 'Sources',
        child: SourceNotesList(notes: report.notes),
      ),
    ];
  }
}
