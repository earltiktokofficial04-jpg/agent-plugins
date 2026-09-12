import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

http.Client _router(Map<String, http.Response Function(http.Request)> routes) =>
    MockClient((request) async {
      for (final entry in routes.entries) {
        if (request.url.host.contains(entry.key)) return entry.value(request);
      }
      return http.Response('unrouted: ${request.url}', 404);
    });

void main() {
  group('ReconRepository with the widened source set', () {
    test('merges hosts from CT, HackerTarget and passive DNS', () async {
      // Each source finds hosts the others miss, so the union is the point.
      final client = _router({
        'cloudflare-dns.com': (_) =>
            http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        'crt.sh': (_) => http.Response(
              jsonEncode([
                {
                  'issuer_name': 'CN=CA',
                  'common_name': 'example.com',
                  'name_value': 'example.com\nct-only.example.com',
                  'not_before': '2026-01-01T00:00:00',
                  'not_after': '2026-04-01T00:00:00',
                },
              ]),
              200,
            ),
        'api.hackertarget.com': (_) => http.Response(
              'ht-only.example.com,1.2.3.4\nexample.com,1.2.3.4\n',
              200,
            ),
        'otx.alienvault.com': (_) => http.Response(
              jsonEncode({
                'passive_dns': [
                  {
                    'hostname': 'passive-only.example.com',
                    'address': '203.0.113.1',
                    'record_type': 'A',
                  },
                ],
              }),
              200,
            ),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
        hackerTarget: HackerTargetService(client: client),
        otx: OtxService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));

      expect(
        report.subdomains,
        containsAll([
          'ct-only.example.com',
          'ht-only.example.com',
          'passive-only.example.com',
        ]),
      );
      // example.com appears in two sources but must be listed once.
      expect(
        report.subdomains.where((host) => host == 'example.com'),
        hasLength(1),
      );
      expect(report.passiveDns, hasLength(1));
    });

    test('discards hosts belonging to other domains', () async {
      // Reverse lookups and shared certificates both return unrelated hosts;
      // attributing those to the target would be factually wrong.
      final client = _router({
        'cloudflare-dns.com': (_) =>
            http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        'crt.sh': (_) => http.Response('[]', 200),
        'api.hackertarget.com': (_) => http.Response(
              'good.example.com,1.2.3.4\n'
              'unrelated.org,1.2.3.4\n'
              'notexample.com,1.2.3.4\n',
              200,
            ),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
        hackerTarget: HackerTargetService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));
      expect(report.subdomains, ['good.example.com']);
    });

    test('one dead source does not cost the others their findings', () async {
      final client = _router({
        'cloudflare-dns.com': (_) =>
            http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        'crt.sh': (_) => http.Response('', 502),
        'api.hackertarget.com': (_) =>
            http.Response('alive.example.com,1.2.3.4\n', 200),
        'otx.alienvault.com': (_) => http.Response('', 500),
        'web.archive.org': (_) => http.Response('', 403),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
        hackerTarget: HackerTargetService(client: client),
        otx: OtxService(client: client),
        wayback: WaybackService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));
      expect(report.subdomains, ['alive.example.com']);
      expect(report.notes.where((note) => !note.ok).length, 3);
    });

    test('collects archived URLs when Wayback answers', () async {
      final client = _router({
        'cloudflare-dns.com': (_) =>
            http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        'crt.sh': (_) => http.Response('[]', 200),
        'web.archive.org': (_) => http.Response(
              jsonEncode([
                ['original', 'timestamp', 'statuscode', 'mimetype'],
                ['http://example.com/.env', '20230101000000', '200', 'text/plain'],
              ]),
              200,
            ),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
        wayback: WaybackService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));
      expect(report.archivedUrls, hasLength(1));
      expect(report.archivedUrls.single.url, endsWith('/.env'));
    });
  });

  group('ThreatIntelRepository with feeds', () {
    ThreatIntelRepository build(http.Client client, {List<ThreatFeed>? feeds}) {
      final keys = InMemoryApiKeyProvider();
      return ThreatIntelRepository(
        virusTotal: VirusTotalService(keys: keys, client: client),
        abuseIpdb: AbuseIpdbService(keys: keys, client: client),
        otx: OtxService(client: client),
        blocklists: BlocklistRepository(
          feedService: ThreatFeedService(client: client),
          feeds: feeds ?? const [],
        ),
      );
    }

    test('adds a blocklist verdict alongside the API verdicts', () async {
      const feed = ThreatFeed(
        id: 'f',
        name: 'Serious feed',
        url: 'https://feeds.test/list.txt',
        severity: FeedSeverity.high,
        description: 'x',
      );

      final client = _router({
        'otx.alienvault.com': (_) =>
            http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200),
        'feeds.test': (_) => http.Response('1.2.3.0/24\n', 200),
      });

      final result = await build(client, feeds: const [feed])
          .enrich(Target.parse('1.2.3.4'));

      final feedVerdict = result.report.verdicts
          .firstWhere((verdict) => verdict.source == 'Public blocklists');
      expect(feedVerdict.severity, IocSeverity.malicious);
      expect(result.report.worstSeverity, IocSeverity.malicious);
      expect(result.blocklist!.hits, hasLength(1));
    });

    test('a contextual-only hit does not raise the overall severity',
        () async {
      const feed = ThreatFeed(
        id: 'tor',
        name: 'Tor exits',
        url: 'https://feeds.test/tor.txt',
        severity: FeedSeverity.contextual,
        description: 'x',
      );

      final client = _router({
        'otx.alienvault.com': (_) =>
            http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200),
        'feeds.test': (_) => http.Response('1.2.3.4\n', 200),
      });

      final result = await build(client, feeds: const [feed])
          .enrich(Target.parse('1.2.3.4'));

      expect(result.report.worstSeverity, IocSeverity.clean);
      expect(result.blocklist!.hits, hasLength(1));
    });

    test('no feed verdict at all when every feed fails to load', () async {
      // A failed download must read as unknown, never as a clean bill.
      const feed = ThreatFeed(
        id: 'f',
        name: 'Dead feed',
        url: 'https://feeds.test/list.txt',
        severity: FeedSeverity.high,
        description: 'x',
      );

      final client = _router({
        'otx.alienvault.com': (_) => http.Response('', 500),
        'feeds.test': (_) => http.Response('', 503),
      });

      final result = await build(client, feeds: const [feed])
          .enrich(Target.parse('1.2.3.4'));

      expect(
        result.report.verdicts.where((v) => v.source == 'Public blocklists'),
        isEmpty,
      );
      expect(result.report.hasOpinion, isFalse);
    });

    test('skips the feed download when asked to', () async {
      var feedFetches = 0;
      const feed = ThreatFeed(
        id: 'f',
        name: 'Feed',
        url: 'https://feeds.test/list.txt',
        severity: FeedSeverity.high,
        description: 'x',
      );

      final client = _router({
        'otx.alienvault.com': (_) =>
            http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200),
        'feeds.test': (_) {
          feedFetches++;
          return http.Response('1.2.3.0/24\n', 200);
        },
      });

      final result = await build(client, feeds: const [feed]).enrich(
        Target.parse('1.2.3.4'),
        checkBlocklists: false,
      );

      expect(feedFetches, 0);
      expect(result.blocklist, isNull);
    });

    test('attaches no blocklist report to a domain lookup', () async {
      // Feeds list IPv4 addresses; carrying an inapplicable report for a
      // domain would put an empty "Public blocklists" panel on the screen.
      var feedFetches = 0;
      const feed = ThreatFeed(
        id: 'f',
        name: 'Feed',
        url: 'https://feeds.test/list.txt',
        severity: FeedSeverity.high,
        description: 'x',
      );

      final client = _router({
        'otx.alienvault.com': (_) =>
            http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200),
        'feeds.test': (_) {
          feedFetches++;
          return http.Response('1.2.3.0/24\n', 200);
        },
      });

      final result = await build(client, feeds: const [feed])
          .enrich(Target.parse('example.com'));

      expect(result.blocklist, isNull);
      expect(feedFetches, 0, reason: 'no pointless download for a domain');
    });

    test('includes the OTX verdict for a domain', () async {
      final client = _router({
        'otx.alienvault.com': (_) =>
            http.Response(jsonEncode({'pulse_info': {'count': 9}}), 200),
      });

      final result =
          await build(client).enrich(Target.parse('evil.example'));
      expect(
        result.report.verdicts.single.source,
        'AlienVault OTX',
      );
      expect(result.report.worstSeverity, IocSeverity.malicious);
    });
  });
}
