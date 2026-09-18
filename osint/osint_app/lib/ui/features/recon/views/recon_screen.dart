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
  ReconViewModel? _observed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewModel = context.read<ReconViewModel>();
    if (identical(_observed, viewModel)) return;
    _observed?.removeListener(_syncInput);
    _observed = viewModel..addListener(_syncInput);
  }

  /// The value last mirrored in, so an unrelated notification cannot
  /// overwrite what the user has since typed.
  String _syncedInput = '';

  /// Mirrors a target handed over from another screen into the field.
  ///
  /// Reacting to any difference between the field and the view model would
  /// mean every notification — toggling a switch, a progress tick — reverted
  /// whatever the user had typed since the last scan. Only an actual change
  /// of the view model's target counts.
  void _syncInput() {
    final input = _observed?.lastInput ?? '';
    if (input.isEmpty || input == _syncedInput) return;
    _syncedInput = input;
    if (_controller.text == input) return;
    _controller.text = input;
  }

  @override
  void dispose() {
    _observed?.removeListener(_syncInput);
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
            'The paid Shodan API, one credit per address. The free InternetDB '
            'view already runs on every scan without a key.',
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
        // The previous target's results must not stay on screen while a new
        // scan runs: the header says one domain and the rows describe
        // another, and nothing on screen says which.
        if (viewModel.isBusy) const ScanInProgress(),
        if (report != null && !viewModel.isBusy) ..._results(context, report),
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
              TruncatedList(
                items: report.subdomains,
                noun: 'hosts',
                itemBuilder: (host) => RecordRow(text: host),
              ),
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final record in report.passiveDns.take(40))
                RecordRow(
                  leading: record.recordType.isEmpty ? null : record.recordType,
                  text:
                      '${record.hostname} → ${record.address}'
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TruncatedList(
                items: [
                  for (final archived in report.archivedUrls) archived.url,
                ],
                noun: 'URLs',
                itemBuilder: (url) => RecordRow(text: url),
              ),
            ],
          ),
        ),
      for (final entry in report.asns.entries)
        SectionCard(
          title: 'Network — ${entry.key}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValueRow(label: 'AS', value: entry.value.label),
              if (entry.value.prefix.isNotEmpty)
                KeyValueRow(label: 'BGP prefix', value: entry.value.prefix),
              if (entry.value.countryCode.isNotEmpty)
                KeyValueRow(label: 'Country', value: entry.value.countryCode),
              if (entry.value.registry.isNotEmpty)
                KeyValueRow(
                  label: 'Registry',
                  value: entry.value.registry.toUpperCase(),
                ),
              if (entry.value.allocated != null)
                KeyValueRow(
                  label: 'Allocated',
                  value: entry.value.allocated!
                      .toIso8601String()
                      .split('T')
                      .first,
                ),
            ],
          ),
        ),
      for (final entry in report.internetDb.entries)
        SectionCard(
          title: 'InternetDB — ${entry.key}',
          trailing: Text(
            'free',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValueRow(
                label: 'Open ports',
                value: entry.value.ports.isEmpty
                    ? 'none recorded'
                    : entry.value.ports.join(', '),
              ),
              if (entry.value.tags.isNotEmpty)
                KeyValueRow(label: 'Tags', value: entry.value.tags.join(', ')),
              if (entry.value.hostnames.isNotEmpty)
                KeyValueRow(
                  label: 'Hostnames',
                  value: entry.value.hostnames.join(', '),
                ),
              if (entry.value.cpes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Software fingerprinted',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                for (final cpe in entry.value.cpes) RecordRow(text: cpe),
              ],
              if (entry.value.vulnerabilities.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${entry.value.vulnerabilities.length} CVE leads — inferred '
                  'from version banners, verify before acting',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                TruncatedList(
                  items: entry.value.vulnerabilities,
                  limit: 25,
                  noun: 'CVEs',
                  itemBuilder: (cve) => RecordRow(text: cve),
                ),
              ],
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
              if (entry.value.operatingSystem.isNotEmpty)
                KeyValueRow(label: 'OS', value: entry.value.operatingSystem),
              KeyValueRow(
                label: 'Open ports',
                value: entry.value.ports.isEmpty
                    ? 'none recorded'
                    : entry.value.ports.join(', '),
              ),
              if (entry.value.lastUpdate != null)
                KeyValueRow(
                  label: 'Last scanned',
                  value: entry.value.lastUpdate!
                      .toIso8601String()
                      .split('T')
                      .first,
                ),
              if (entry.value.hostnames.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Reverse hostnames — other names on this address',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TruncatedList(
                  items: entry.value.hostnames,
                  limit: 25,
                  noun: 'hostnames',
                  itemBuilder: (hostname) => RecordRow(text: hostname),
                ),
              ],
              TruncatedList(
                items: [
                  for (final service in entry.value.services) service.label,
                ],
                limit: 30,
                noun: 'services',
                itemBuilder: (label) => RecordRow(text: label),
              ),
              if (entry.value.vulnerabilities.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'CVE leads (inferred from banners — verify before acting)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                TruncatedList(
                  items: entry.value.vulnerabilities,
                  limit: 25,
                  noun: 'CVEs',
                  itemBuilder: (cve) => RecordRow(text: cve),
                ),
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
