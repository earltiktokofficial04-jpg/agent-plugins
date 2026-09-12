import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../core/scan_status.dart';
import '../../../core/widgets.dart';
import '../view_models/recon_view_model.dart';

/// Infrastructure and attack-surface recon for a domain.
class ReconScreen extends StatefulWidget {
  const ReconScreen({required this.onOpenSettings, super.key});

  final VoidCallback onOpenSettings;

  @override
  State<ReconScreen> createState() => _ReconScreenState();
}

class _ReconScreenState extends State<ReconScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ReconViewModel>();
    final report = viewModel.report;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TargetField(
          controller: _controller,
          isBusy: viewModel.isBusy,
          onSubmit: () => viewModel.scan(_controller.text),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: viewModel.enrichHosts,
          onChanged: viewModel.isBusy ? null : viewModel.setEnrichHosts,
          title: const Text('Enrich hosts with Shodan'),
          subtitle: const Text(
            'Reads Shodan\'s existing scan data. Costs one API credit per '
            'resolved address.',
          ),
        ),
        if (viewModel.status == ScanStatus.rejected)
          _Rejection(message: viewModel.rejection),
        if (viewModel.status == ScanStatus.idle)
          const EmptyState(
            icon: Icons.travel_explore,
            message:
                'Enter a domain to map its DNS records, certificate history '
                'and known hosts.\n\nEvery source is passive — nothing is '
                'sent to the target.',
          ),
        if (report != null) ..._results(context, report),
      ],
    );
  }

  List<Widget> _results(BuildContext context, ReconReport report) {
    final byType = <DnsRecordType, List<DnsRecord>>{};
    for (final record in report.dnsRecords) {
      byType.putIfAbsent(record.type, () => []).add(record);
    }

    return [
      SectionCard(
        title: 'Target',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyValueRow(label: 'Domain', value: report.target.value),
            KeyValueRow(
              label: 'Addresses',
              value: report.addresses.isEmpty
                  ? 'none resolved'
                  : report.addresses.join(', '),
            ),
            KeyValueRow(
              label: 'Hosts found',
              value: '${report.subdomains.length}',
            ),
            KeyValueRow(
              label: 'Certificates',
              value: '${report.certificates.length}',
            ),
          ],
        ),
      ),
      if (byType.isNotEmpty)
        SectionCard(
          title: 'DNS records',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final type in byType.keys)
                for (final record in byType[type]!)
                  RecordRow(leading: type.label, text: record.data),
            ],
          ),
        ),
      if (report.subdomains.isNotEmpty)
        SectionCard(
          title: 'Discovered hosts',
          trailing: Text('${report.subdomains.length}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final host in report.subdomains) RecordRow(text: host),
            ],
          ),
        ),
      if (report.passiveDns.isNotEmpty)
        SectionCard(
          title: 'Passive DNS history',
          trailing: Text('${report.passiveDns.length}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Where these names pointed in the past, which live DNS '
                  'cannot show.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              for (final record in report.passiveDns.take(40))
                RecordRow(
                  leading: record.recordType.isEmpty ? null : record.recordType,
                  text: '${record.hostname} → ${record.address}'
                      '${record.lastSeen == null ? '' : '  (last seen '
                          '${record.lastSeen!.toIso8601String().split('T').first})'}',
                ),
            ],
          ),
        ),
      if (report.archivedUrls.isNotEmpty)
        SectionCard(
          title: 'Archived URLs',
          trailing: Text('${report.archivedUrls.length}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Paths the Internet Archive captured. These may no longer '
                  'be linked or served.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              for (final archived in report.archivedUrls.take(60))
                RecordRow(
                  leading: archived.statusCode.isEmpty
                      ? null
                      : archived.statusCode,
                  text: archived.url,
                ),
            ],
          ),
        ),
      for (final entry in report.hosts.entries)
        SectionCard(
          title: 'Shodan — ${entry.key}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.value.organisation.isNotEmpty)
                KeyValueRow(
                  label: 'Organisation',
                  value: entry.value.organisation,
                ),
              KeyValueRow(
                label: 'Open ports',
                value: entry.value.ports.isEmpty
                    ? 'none recorded'
                    : entry.value.ports.join(', '),
              ),
              for (final service in entry.value.services)
                RecordRow(text: service.label),
              if (entry.value.vulnerabilities.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'CVE leads (inferred from banners — verify before acting)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
                for (final cve in entry.value.vulnerabilities)
                  RecordRow(text: cve),
              ],
            ],
          ),
        ),
      SectionCard(
        title: 'Sources',
        child: SourceNotesList(
          notes: report.notes,
          onOpenSettings: widget.onOpenSettings,
        ),
      ),
    ];
  }
}

/// Shown when the view model refused the input.
class _Rejection extends StatelessWidget {
  const _Rejection({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
