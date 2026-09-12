import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

/// Serves plausible registry payloads, with any named registry made to fail.
IanaRegistryService _registry({Set<String> failing = const {}}) =>
    IanaRegistryService(
      client: MockClient((request) async {
        final url = request.url.toString();
        String? which;
        if (url.contains('tlds-alpha')) which = 'tld';
        if (url.contains('public_suffix')) which = 'psl';
        if (url.contains('rdap')) which = 'rdap';
        if (url.contains('log_list')) which = 'ct';

        if (which == null || failing.contains(which)) {
          return http.Response('', 503);
        }

        return switch (which) {
          'tld' => http.Response('# v1\nCOM\nNET\nORG\n', 200),
          'psl' => http.Response('// x\ncom\nnet\norg\ncom.my\nco.uk\n', 200),
          'rdap' => http.Response(
              jsonEncode({
                'services': [
                  [
                    ['com', 'net'],
                    ['https://a.test/'],
                  ],
                  [
                    ['org'],
                    ['https://b.test/'],
                  ],
                ],
              }),
              200,
            ),
          _ => http.Response(
              jsonEncode({
                'operators': [
                  {
                    'name': 'Op',
                    'logs': [
                      {'url': 'https://l1.test/'},
                      {'url': 'https://l2.test/'},
                    ],
                  },
                ],
              }),
              200,
            ),
        };
      }),
    );

void main() {
  group('CatalogRepository', () {
    test('counts each section from the registry that publishes it', () async {
      final repository = CatalogRepository(
        registry: _registry(),
        feeds: ThreatFeeds.all,
        now: () => DateTime.utc(2026, 9, 12),
      );

      final catalog = await repository.load();

      int countOf(String name) =>
          catalog.sections.firstWhere((s) => s.name == name).count;

      expect(countOf('RDAP registry servers'), 2);
      expect(countOf('Certificate Transparency logs'), 2);
      expect(countOf('Top-level domains'), 3);
      expect(countOf('Public suffixes'), 5);
      expect(countOf('Threat feeds'), ThreatFeeds.all.length);
      expect(countOf('API integrations'), CatalogRepository.defaultApiCount);
      expect(catalog.fetchedAt, DateTime.utc(2026, 9, 12));
    });

    test('keeps queryable sources and namespaces in separate totals', () {
      // Conflating them would inflate the headline: a public suffix is
      // somewhere a domain can exist, not a server that answers questions.
      final catalog = SourceCatalog(
        sections: const [
          CatalogSection(
            name: 'servers',
            kind: CatalogKind.queryableEndpoint,
            count: 590,
            origin: 'x',
          ),
          CatalogSection(
            name: 'feeds',
            kind: CatalogKind.feed,
            count: 9,
            origin: 'x',
          ),
          CatalogSection(
            name: 'apis',
            kind: CatalogKind.api,
            count: 9,
            origin: 'x',
          ),
          CatalogSection(
            name: 'suffixes',
            kind: CatalogKind.namespace,
            count: 10325,
            origin: 'x',
          ),
        ],
        fetchedAt: DateTime.utc(2026),
      );

      expect(catalog.queryableCount, 608);
      expect(catalog.namespaceCount, 10325);
      expect(catalog.totalCount, 10933);
    });

    test('a failed registry yields a zero, stale section, not an abort',
        () async {
      // A catalogue missing one section is far more useful than no catalogue,
      // provided the gap is visible rather than silently counted as zero.
      final repository = CatalogRepository(registry: _registry(failing: {'psl'}));
      final catalog = await repository.load();

      final suffixes =
          catalog.sections.firstWhere((s) => s.name == 'Public suffixes');
      expect(suffixes.count, 0);
      expect(suffixes.stale, isTrue);
      expect(suffixes.detail, contains('Unavailable'));
      expect(catalog.hasStaleSections, isTrue);

      // The sections that did load are unaffected.
      expect(
        catalog.sections.firstWhere((s) => s.name == 'Top-level domains').count,
        3,
      );
    });

    test('reports no stale sections when every registry answers', () async {
      final catalog = await CatalogRepository(registry: _registry()).load();
      expect(catalog.hasStaleSections, isFalse);
    });

    test('caches the last successful catalogue', () async {
      final repository = CatalogRepository(registry: _registry());
      expect(repository.cached, isNull);
      final catalog = await repository.load();
      expect(repository.cached, same(catalog));
    });

    test('reports progress for each registry fetched', () async {
      final stages = <String>[];
      await CatalogRepository(registry: _registry())
          .load(onProgress: stages.add);
      expect(stages, hasLength(4));
      expect(stages.first, contains('RDAP'));
    });

    test('ofKind groups sections for display', () async {
      final catalog = await CatalogRepository(registry: _registry()).load();
      expect(catalog.ofKind(CatalogKind.namespace), hasLength(2));
      expect(catalog.ofKind(CatalogKind.feed), hasLength(1));
    });
  });
}
