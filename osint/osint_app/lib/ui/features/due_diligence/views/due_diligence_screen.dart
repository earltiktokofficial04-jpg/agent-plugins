import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../core/scan_status.dart';
import '../../../core/widgets.dart';
import '../view_models/due_diligence_view_model.dart';

/// Public-record profile of an organisation's domain.
class DueDiligenceScreen extends StatefulWidget {
  const DueDiligenceScreen({super.key});

  @override
  State<DueDiligenceScreen> createState() => _DueDiligenceScreenState();
}

class _DueDiligenceScreenState extends State<DueDiligenceScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<DueDiligenceViewModel>();
    final report = viewModel.report;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TargetField(
          controller: _controller,
          isBusy: viewModel.isBusy,
          label: 'Organisation domain',
          onSubmit: () => viewModel.profile(_controller.text),
        ),
        if (viewModel.status == ScanStatus.rejected)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              viewModel.rejection,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (viewModel.status == ScanStatus.idle)
          const EmptyState(
            icon: Icons.business_outlined,
            message:
                'Who registered the domain and when, who runs its DNS and '
                'mail, and whether its mail is authenticated.\n\nNo API key '
                'needed.',
          ),
        if (report != null) ..._results(context, viewModel, report),
      ],
    );
  }

  List<Widget> _results(
    BuildContext context,
    DueDiligenceViewModel viewModel,
    DueDiligenceReport report,
  ) {
    final theme = Theme.of(context);
    final registration = report.registration;
    final mail = report.mailSecurity;
    final age = viewModel.registrationAge;

    return [
      SectionCard(
        title: 'Registration',
        child: registration == null
            ? const Text('No registration record was returned.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyValueRow(label: 'Domain', value: registration.domain),
                  KeyValueRow(
                    label: 'Registrar',
                    value: registration.registrar.isEmpty
                        ? 'not published'
                        : registration.registrar,
                  ),
                  KeyValueRow(
                    label: 'Registered',
                    value: _date(registration.registered),
                  ),
                  KeyValueRow(
                    label: 'Expires',
                    value: _date(registration.expires),
                  ),
                  if (age != null)
                    KeyValueRow(
                      label: 'Age',
                      value:
                          '${(age.inDays / 365).toStringAsFixed(1)} years '
                          '(${age.inDays} days)',
                    ),
                  KeyValueRow(
                    label: 'DNSSEC',
                    value: registration.dnssecSigned ? 'signed' : 'unsigned',
                  ),
                  if (registration.statuses.isNotEmpty)
                    KeyValueRow(
                      label: 'Status',
                      value: registration.statuses.join(', '),
                    ),
                  if (registration.registryServer.isNotEmpty)
                    KeyValueRow(
                      label: 'Answered by',
                      value: registration.registryServer,
                    ),
                  if (viewModel.isRecentlyRegistered)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Registered within the last 90 days — treat any '
                        'business claim made on this domain with caution.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
      ),
      if (mail != null)
        SectionCard(
          title: 'Mail security',
          trailing: mail.isSpoofable
              ? Chip(
                  label: const Text('Spoofable'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: theme.colorScheme.errorContainer,
                  labelStyle: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValueRow(
                label: 'Accepts mail',
                value: mail.acceptsMail
                    ? mail.mailExchangers.join(', ')
                    : 'no MX records',
              ),
              KeyValueRow(
                label: 'SPF',
                value: mail.spf == null
                    ? 'not published'
                    : '${_spfLabel(mail.spf!.qualifier)} · '
                          '${mail.spf!.lookupCount} DNS lookups',
              ),
              KeyValueRow(
                label: 'DMARC',
                value: mail.dmarc == null
                    ? 'not published'
                    : 'p=${mail.dmarc!.policy.name}'
                          '${mail.dmarc!.subdomainPolicy == null ? '' : ' sp=${mail.dmarc!.subdomainPolicy!.name}'}'
                          '${mail.dmarc!.percentage == 100 ? '' : ' pct=${mail.dmarc!.percentage}'}',
              ),
              KeyValueRow(
                label: 'MTA-STS',
                value: mail.hasMtaSts ? 'published' : 'not published',
              ),
              KeyValueRow(
                label: 'DANE',
                value: mail.hasDane ? 'published' : 'not published',
              ),
              if (mail.findings.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final finding in mail.findings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: _severityColour(finding.severity, theme),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                finding.title,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: _severityColour(
                                    finding.severity,
                                    theme,
                                  ),
                                ),
                              ),
                              Text(
                                finding.detail,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      if (registration != null && registration.nameservers.isNotEmpty)
        SectionCard(
          title: 'Nameservers',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final nameserver in registration.nameservers)
                RecordRow(text: nameserver),
            ],
          ),
        ),
      SectionCard(
        title: 'Certificate footprint',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyValueRow(
              label: 'Known hosts',
              value: '${report.subdomainCount}',
            ),
            const SizedBox(height: 4),
            if (report.certificateIssuers.isEmpty)
              const Text('No issuing CAs found.')
            else
              for (final issuer in report.certificateIssuers.take(8))
                RecordRow(text: issuer),
          ],
        ),
      ),
      SectionCard(
        title: 'Sources',
        child: SourceNotesList(notes: report.notes),
      ),
    ];
  }

  /// A short, plain description of what an SPF qualifier means.
  static String _spfLabel(SpfQualifier qualifier) => switch (qualifier) {
    SpfQualifier.fail => 'enforcing (-all)',
    SpfQualifier.softFail => 'soft-fail only (~all)',
    SpfQualifier.neutral => 'neutral (?all)',
    SpfQualifier.pass => 'authorises everyone (+all)',
    SpfQualifier.none => 'no all mechanism',
  };

  static Color _severityColour(MailFindingSeverity severity, ThemeData theme) =>
      switch (severity) {
        MailFindingSeverity.high => theme.colorScheme.error,
        MailFindingSeverity.medium => const Color(0xFFB26A00),
        MailFindingSeverity.low => theme.colorScheme.onSurfaceVariant,
      };

  static String _date(DateTime? value) => value == null
      ? 'not published'
      : value.toIso8601String().split('T').first;
}
