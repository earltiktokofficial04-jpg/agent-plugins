import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

import '../../../core/scan_status.dart';
import '../../../core/widgets.dart';
import '../view_models/sources_view_model.dart';

/// Lists every source the tool can consult, with counts traced to the
/// registry that publishes each list.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final viewModel = context.read<SourcesViewModel>();
      if (viewModel.catalog == null) viewModel.load();
    });
  }

  static String _grouped(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  static String _kindLabel(CatalogKind kind) => switch (kind) {
        CatalogKind.queryableEndpoint => 'Queryable servers',
        CatalogKind.feed => 'Bulk threat feeds',
        CatalogKind.api => 'API integrations',
        CatalogKind.namespace => 'Sweep namespaces',
      };

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SourcesViewModel>();
    final catalog = viewModel.catalog;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: viewModel.isBusy ? null : viewModel.load,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (viewModel.isBusy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(viewModel.stage, style: theme.textTheme.bodySmall),
          ],
          if (catalog == null && viewModel.status != ScanStatus.running)
            const EmptyState(
              icon: Icons.inventory_2_outlined,
              message: 'Fetching the source catalogue…',
            ),
          if (catalog != null) ...[
            SectionCard(
              title: 'Catalogue',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Total(
                    value: _grouped(catalog.queryableCount),
                    label: 'queryable sources',
                    detail:
                        'Registry servers, CT logs, threat feeds and API '
                        'integrations — things that answer a question.',
                  ),
                  const SizedBox(height: 12),
                  _Total(
                    value: _grouped(catalog.namespaceCount),
                    label: 'sweep namespaces',
                    detail:
                        'Places a domain can be registered, and so places a '
                        'brand can be squatted. Not queried for data.',
                  ),
                  const Divider(height: 24),
                  KeyValueRow(
                    label: 'Total entries',
                    value: _grouped(catalog.totalCount),
                  ),
                  KeyValueRow(
                    label: 'Fetched',
                    value: catalog.fetchedAt.toLocal().toString().split('.').first,
                  ),
                  if (catalog.hasStaleSections)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Some registries could not be reached, so the totals '
                        'below are incomplete. The affected rows are marked.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
            for (final kind in CatalogKind.values)
              if (catalog.ofKind(kind).isNotEmpty)
                SectionCard(
                  title: _kindLabel(kind),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final section in catalog.ofKind(kind))
                        _SectionRow(section: section, format: _grouped),
                    ],
                  ),
                ),
            SectionCard(
              title: 'Threat feeds consulted',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final feed in ThreatFeeds.all)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  feed.name,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                feed.severity.name,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            feed.description,
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
    );
  }
}

/// A large headline figure with its meaning spelled out underneath.
class _Total extends StatelessWidget {
  const _Total({
    required this.value,
    required this.label,
    required this.detail,
  });

  final String value;
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodyMedium),
          ],
        ),
        Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// One catalogue row: count, name, where the list came from.
class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.section, required this.format});

  final CatalogSection section;
  final String Function(int value) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  format(section.count),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: section.stale
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.name,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (section.stale)
                Icon(
                  Icons.cloud_off_outlined,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 84, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (section.detail.isNotEmpty)
                  Text(
                    section.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                Text(
                  'source: ${section.origin}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
