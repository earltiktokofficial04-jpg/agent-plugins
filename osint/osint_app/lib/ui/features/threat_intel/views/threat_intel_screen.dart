import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../core/scan_status.dart';
import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../view_models/threat_intel_view_model.dart';

/// Reputation enrichment for an indicator of compromise.
class ThreatIntelScreen extends StatefulWidget {
  const ThreatIntelScreen({required this.onOpenSettings, super.key});

  final VoidCallback onOpenSettings;

  @override
  State<ThreatIntelScreen> createState() => _ThreatIntelScreenState();
}

class _ThreatIntelScreenState extends State<ThreatIntelScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ThreatIntelViewModel>();
    final result = viewModel.result;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TargetField(
          controller: _controller,
          isBusy: viewModel.isBusy,
          label: 'Indicator',
          hint: 'domain, IP, URL or file hash',
          onSubmit: () => viewModel.enrich(_controller.text),
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
            icon: Icons.shield_outlined,
            message:
                'Look an indicator up across reputation sources.\n\nNeeds a '
                'VirusTotal or AbuseIPDB key — both have free tiers.',
          ),
        if (result != null) ..._results(context, viewModel, result),
      ],
    );
  }

  /// Renders bulk feed membership.
  ///
  /// Shows the corpus size actually searched, so a thin check from failed
  /// downloads is never mistaken for a thorough clean result.
  Widget _blocklistCard(BuildContext context, BlocklistReport report) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Public blocklists',
      trailing: Text(
        '${report.feedsChecked} feeds',
        style: theme.textTheme.labelMedium,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyValueRow(
            label: 'Entries searched',
            value: '${report.entriesSearched}',
          ),
          const SizedBox(height: 4),
          if (report.hits.isEmpty)
            Text(
              report.feedsChecked == 0
                  ? 'No feed could be loaded — this is not an all-clear.'
                  : 'Not listed by any feed that loaded.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: report.feedsChecked == 0
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final hit in report.hits)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            hit.feed.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          hit.feed.severity.name,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: hit.feed.severity == FeedSeverity.contextual
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      'listed as ${hit.matchedBlock}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                    Text(
                      hit.feed.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  List<Widget> _results(
    BuildContext context,
    ThreatIntelViewModel viewModel,
    ThreatIntelResult result,
  ) {
    final theme = Theme.of(context);
    final report = result.report;
    final severity = report.worstSeverity;

    return [
      SectionCard(
        title: 'Verdict',
        trailing: Chip(
          label: Text(severityLabel(severity)),
          backgroundColor:
              severityColor(severity, theme.colorScheme).withValues(alpha: 0.14),
          side: BorderSide(
            color: severityColor(severity, theme.colorScheme),
          ),
          labelStyle: theme.textTheme.labelMedium?.copyWith(
            color: severityColor(severity, theme.colorScheme),
            fontWeight: FontWeight.w700,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyValueRow(label: 'Indicator', value: report.indicator),
            KeyValueRow(
              label: 'Type',
              value: viewModel.target?.kind.name ?? 'unknown',
            ),
            if (!report.hasOpinion)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No source returned an opinion. This is not an all-clear — '
                  'check the source list below.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      for (final verdict in report.verdicts)
        SectionCard(
          title: verdict.source,
          trailing: Text(
            severityLabel(verdict.severity),
            style: theme.textTheme.labelMedium?.copyWith(
              color: severityColor(verdict.severity, theme.colorScheme),
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (verdict.totalEngines > 0)
                KeyValueRow(
                  label: 'Detections',
                  value: '${verdict.detections} of ${verdict.totalEngines} '
                      'engines',
                )
              else if (verdict.detections > 0)
                KeyValueRow(
                  label: 'Reports',
                  value: '${verdict.detections}',
                ),
              if (verdict.score != null)
                KeyValueRow(
                  label: 'Confidence',
                  value: '${verdict.score}/100',
                ),
              for (final entry in verdict.details.entries)
                KeyValueRow(label: entry.key, value: entry.value),
            ],
          ),
        ),
      if (result.blocklist != null) _blocklistCard(context, result.blocklist!),
      SectionCard(
        title: 'Sources',
        child: SourceNotesList(
          notes: result.notes,
          onOpenSettings: widget.onOpenSettings,
        ),
      ),
    ];
  }
}
