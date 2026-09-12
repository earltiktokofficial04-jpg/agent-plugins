import '../models/catalog.dart';
import '../models/source_result.dart';
import '../models/threat_feed.dart';
import '../services/iana_registry_service.dart';

/// Builds the enumerated catalogue of everything this tool can consult.
///
/// The point of enumerating rather than asserting: each section's count comes
/// from a list published by the body that governs it, so the total can be
/// checked against the source rather than taken on trust. Nothing here invents
/// a number.
class CatalogRepository {
  CatalogRepository({
    required IanaRegistryService registry,
    List<ThreatFeed> feeds = ThreatFeeds.all,
    int handWrittenApiCount = defaultApiCount,
    DateTime Function() now = DateTime.now,
  })  : _registry = registry,
        _feeds = feeds,
        _apiCount = handWrittenApiCount,
        _now = now;

  final IanaRegistryService _registry;
  final List<ThreatFeed> _feeds;
  final int _apiCount;
  final DateTime Function() _now;

  /// Hand-written API integrations: DNS-over-HTTPS, crt.sh, RDAP, VirusTotal,
  /// AbuseIPDB, Shodan, OTX, HackerTarget and Wayback.
  static const int defaultApiCount = 9;

  SourceCatalog? _cached;

  /// The catalogue from the last successful load, if any.
  SourceCatalog? get cached => _cached;

  /// Fetches every registry and assembles the catalogue.
  ///
  /// A registry that fails contributes a zero-count section flagged [stale]
  /// rather than aborting the load: a catalogue missing one section is far
  /// more useful than no catalogue, provided the gap is visible.
  Future<SourceCatalog> load({
    void Function(String stage)? onProgress,
  }) async {
    onProgress?.call('Fetching IANA RDAP bootstrap');
    final rdapResult = await _registry.rdapBootstrap();

    onProgress?.call('Fetching Certificate Transparency log list');
    final ctResult = await _registry.ctLogs();

    onProgress?.call('Fetching IANA TLD list');
    final tldResult = await _registry.tlds();

    onProgress?.call('Fetching Public Suffix List');
    final suffixResult = await _registry.publicSuffixes();

    final sections = <CatalogSection>[];

    final bootstrap = rdapResult.valueOrNull;
    sections.add(
      CatalogSection(
        name: 'RDAP registry servers',
        kind: CatalogKind.queryableEndpoint,
        count: bootstrap?.serverCount ?? 0,
        origin: IanaRegistryService.rdapSource,
        detail: bootstrap == null
            ? _failureDetail(rdapResult)
            : 'Authoritative for ${bootstrap.tldCount} TLDs. Each is run by '
                'the registry itself, so a lookup goes to the operator rather '
                'than a middleman.',
        stale: bootstrap == null,
      ),
    );

    final ctLogs = ctResult.valueOrNull;
    sections.add(
      CatalogSection(
        name: 'Certificate Transparency logs',
        kind: CatalogKind.queryableEndpoint,
        count: ctLogs?.length ?? 0,
        origin: IanaRegistryService.ctSource,
        detail: ctLogs == null
            ? _failureDetail(ctResult)
            : 'Across ${ctLogs.map((log) => log.operator).toSet().length} '
                'operators. Queried in aggregate through crt.sh.',
        stale: ctLogs == null,
      ),
    );

    sections.add(
      CatalogSection(
        name: 'Threat feeds',
        kind: CatalogKind.feed,
        count: _feeds.length,
        origin: 'Bundled registry',
        detail: 'Public bulk lists, fetched whole and searched locally.',
      ),
    );

    sections.add(
      CatalogSection(
        name: 'API integrations',
        kind: CatalogKind.api,
        count: _apiCount,
        origin: 'Bundled',
        detail: 'Hand-written clients, each parsing one service\'s responses.',
      ),
    );

    final suffixes = suffixResult.valueOrNull;
    sections.add(
      CatalogSection(
        name: 'Public suffixes',
        kind: CatalogKind.namespace,
        count: suffixes?.length ?? 0,
        origin: IanaRegistryService.suffixSource,
        detail: suffixes == null
            ? _failureDetail(suffixResult)
            : 'Every namespace a domain can be registered under, and so every '
                'namespace a brand can be squatted in.',
        stale: suffixes == null,
      ),
    );

    final tlds = tldResult.valueOrNull;
    sections.add(
      CatalogSection(
        name: 'Top-level domains',
        kind: CatalogKind.namespace,
        count: tlds?.length ?? 0,
        origin: IanaRegistryService.tldSource,
        detail: tlds == null
            ? _failureDetail(tldResult)
            : 'Delegated TLDs. A subset of the public suffixes above.',
        stale: tlds == null,
      ),
    );

    final catalog = SourceCatalog(sections: sections, fetchedAt: _now());
    _cached = catalog;
    return catalog;
  }

  static String _failureDetail(SourceResult<Object?> result) =>
      switch (result) {
        SourceFailure(:final message) => 'Unavailable — $message',
        SourceEmpty(:final detail) => 'Empty — $detail',
        _ => 'Unavailable',
      };
}
