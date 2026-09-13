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
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
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
    final posture = report.mailPosture;
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
                      value: '${(age.inDays / 365).toStringAsFixed(1)} years '
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
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
      ),
      SectionCard(
        title: 'Mail posture',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyValueRow(
              label: 'Accepts mail',
              value: posture.hasMx ? 'yes' : 'no',
            ),
            KeyValueRow(label: 'SPF', value: posture.hasSpf ? 'yes' : 'no'),
            KeyValueRow(
              label: 'DMARC',
              value: posture.hasDmarc ? 'yes' : 'no',
            ),
            if (posture.sendsMailUnauthenticated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Accepts mail but publishes no SPF record — the domain is '
                  'spoofable.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
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

  static String _date(DateTime? value) =>
      value == null ? 'not published' : value.toIso8601String().split('T').first;
}
