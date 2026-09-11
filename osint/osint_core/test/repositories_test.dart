import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

/// Routes requests to the right canned response by host, so one client can
/// stand in for the several services a repository fans out to.
http.Client _router(Map<String, http.Response Function(http.Request)> routes) =>
    MockClient((request) async {
      for (final entry in routes.entries) {
        if (request.url.host.contains(entry.key)) return entry.value(request);
      }
      return http.Response('unrouted: ${request.url}', 404);
    });

http.Response _dnsAnswer(List<Map<String, Object>> answers) => http.Response(
      jsonEncode({'Status': 0, 'Answer': answers}),
      200,
    );

void main() {
  group('ReconRepository', () {
    test('merges DNS records with CT-derived subdomains', () async {
      final client = _router({
        'cloudflare-dns.com': (request) {
          final type = request.url.queryParameters['type'];
          if (type == '1') {
            return _dnsAnswer([
              {
                'name': 'example.com',
                'type': 1,
                'TTL': 60,
                'data': '93.184.216.34',
              },
            ]);
          }
          if (type == '15') {
            return _dnsAnswer([
              {
                'name': 'example.com',
                'type': 15,
                'TTL': 60,
                'data': '10 mail.example.com',
              },
            ]);
          }
          return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
        },
        'crt.sh': (_) => http.Response(
              jsonEncode([
                {
                  'issuer_name': "CN=R3, O=Let's Encrypt",
                  'common_name': 'example.com',
                  'name_value': 'example.com\napi.example.com\nvpn.example.com',
                  'not_before': '2026-01-01T00:00:00',
                  'not_after': '2026-04-01T00:00:00',
                },
              ]),
              200,
            ),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));
      expect(report.addresses, ['93.184.216.34']);
      expect(report.subdomains,
          ['api.example.com', 'example.com', 'vpn.example.com']);
      expect(report.certificates, hasLength(1));
      expect(report.dnsRecords.any((r) => r.type == DnsRecordType.mx), isTrue);
      expect(report.notes.every((note) => note.ok), isTrue);
    });

    test('still reports DNS findings when crt.sh fails', () async {
      // Partial failure is the normal case; one dead source must not discard
      // the other's findings.
      final client = _router({
        'cloudflare-dns.com': (_) => _dnsAnswer([
              {
                'name': 'example.com',
                'type': 1,
                'TTL': 60,
                'data': '1.2.3.4',
              },
            ]),
        'crt.sh': (_) => http.Response('', 502),
      });

      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
      );

      final report = await repository.scan(Target.parse('example.com'));
      expect(report.addresses, contains('1.2.3.4'));
      expect(report.subdomains, isEmpty);
      final failed = report.notes.where((note) => !note.ok).toList();
      expect(failed, hasLength(1));
      expect(failed.single.source, 'crt.sh');
    });

    test('refuses a non-domain target with an explanatory note', () async {
      final repository = ReconRepository(
        dns: DnsOverHttpsService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
        crtSh: CrtShService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
      );

      final report = await repository.scan(Target.parse('8.8.8.8'));
      expect(report.notes.single.ok, isFalse);
      expect(report.notes.single.message, contains('domain'));
    });

    test('enriches resolved addresses with Shodan only when asked', () async {
      var shodanCalls = 0;
      final client = _router({
        'cloudflare-dns.com': (request) =>
            request.url.queryParameters['type'] == '1'
                ? _dnsAnswer([
                    {
                      'name': 'example.com',
                      'type': 1,
                      'TTL': 60,
                      'data': '1.2.3.4',
                    },
                  ])
                : http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        'crt.sh': (_) => http.Response('[]', 200),
        'api.shodan.io': (_) {
          shodanCalls++;
          return http.Response(
            jsonEncode({'ip_str': '1.2.3.4', 'ports': [443]}),
            200,
          );
        },
      });

      final shodan = ShodanHostService(
        keys: InMemoryApiKeyProvider({ApiKeySource.shodan: 'k'}),
        client: client,
      );
      final repository = ReconRepository(
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
        shodan: shodan,
      );

      final without = await repository.scan(Target.parse('example.com'));
      expect(shodanCalls, 0);
      expect(without.hosts, isEmpty);

      final with_ = await repository.scan(
        Target.parse('example.com'),
        enrichHosts: true,
      );
      expect(shodanCalls, 1);
      expect(with_.hosts['1.2.3.4']!.ports, [443]);
    });
  });

  group('ThreatIntelRepository', () {
    test('keeps one source\'s verdict when the other has no key', () async {
      final client = _router({
        'virustotal.com': (_) => http.Response(
              jsonEncode({
                'data': {
                  'attributes': {
                    'last_analysis_stats': {
                      'malicious': 9,
                      'suspicious': 0,
                      'harmless': 50,
                      'undetected': 3,
                    },
                  },
                },
              }),
              200,
            ),
      });

      final keys = InMemoryApiKeyProvider({ApiKeySource.virusTotal: 'vt'});
      final repository = ThreatIntelRepository(
        virusTotal: VirusTotalService(keys: keys, client: client),
        abuseIpdb: AbuseIpdbService(keys: keys, client: client),
      );

      final result = await repository.enrich(Target.parse('1.2.3.4'));
      expect(result.report.worstSeverity, IocSeverity.malicious);
      expect(result.report.verdicts, hasLength(1));

      final keyNote = result.notes.where((note) => note.needsApiKey).single;
      expect(keyNote.source, 'AbuseIPDB');
    });

    test('reports no opinion when every source is unavailable', () async {
      final repository = ThreatIntelRepository(
        virusTotal: VirusTotalService(
          keys: InMemoryApiKeyProvider(),
          client: MockClient((_) async => http.Response('', 500)),
        ),
        abuseIpdb: AbuseIpdbService(
          keys: InMemoryApiKeyProvider(),
          client: MockClient((_) async => http.Response('', 500)),
        ),
      );

      final result = await repository.enrich(Target.parse('1.2.3.4'));
      expect(result.report.hasOpinion, isFalse);
      expect(result.notes.every((note) => !note.ok), isTrue);
    });
  });

  group('DueDiligenceRepository', () {
    test('assembles registration, mail posture and issuer history', () async {
      final client = _router({
        'rdap.org': (_) => http.Response(
              jsonEncode({
                'ldhName': 'example.com',
                'events': [
                  {
                    'eventAction': 'registration',
                    'eventDate': '2026-08-01T00:00:00Z',
                  },
                ],
                'entities': [
                  {
                    'roles': ['registrar'],
                    'vcardArray': [
                      'vcard',
                      [
                        ['fn', <String, Object>{}, 'text', 'Example Registrar'],
                      ],
                    ],
                  },
                ],
              }),
              200,
            ),
        'cloudflare-dns.com': (request) {
          final type = request.url.queryParameters['type'];
          if (type == '15') {
            return _dnsAnswer([
              {
                'name': 'example.com',
                'type': 15,
                'TTL': 60,
                'data': '10 mail.example.com',
              },
            ]);
          }
          return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
        },
        'crt.sh': (_) => http.Response(
              jsonEncode([
                {
                  'issuer_name': 'CN=Old CA',
                  'common_name': 'example.com',
                  'name_value': 'example.com',
                  'not_before': '2024-01-01T00:00:00',
                  'not_after': '2024-04-01T00:00:00',
                },
                {
                  'issuer_name': 'CN=New CA',
                  'common_name': 'a.example.com',
                  'name_value': 'a.example.com',
                  'not_before': '2026-01-01T00:00:00',
                  'not_after': '2026-04-01T00:00:00',
                },
              ]),
              200,
            ),
      });

      final repository = DueDiligenceRepository(
        rdap: RdapService(client: client),
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
      );

      final report = await repository.profile(Target.parse('example.com'));
      expect(report.registration!.registrar, 'Example Registrar');
      // A domain registered weeks ago with live mail and no SPF is exactly the
      // profile this module exists to surface.
      expect(report.mailPosture.sendsMailUnauthenticated, isTrue);
      expect(report.certificateIssuers, ['CN=New CA', 'CN=Old CA']);
      expect(report.subdomainCount, 2);
    });

    test('reports an unregistered domain without failing the profile',
        () async {
      final client = _router({
        'rdap.org': (_) => http.Response('', 404),
        'cloudflare-dns.com': (_) =>
            http.Response(jsonEncode({'Status': 3}), 200),
        'crt.sh': (_) => http.Response('[]', 200),
      });

      final repository = DueDiligenceRepository(
        rdap: RdapService(client: client),
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
      );

      final report = await repository.profile(Target.parse('nope.example'));
      expect(report.registration, isNull);
      expect(report.notes.every((note) => note.ok), isTrue);
      final rdapNote =
          report.notes.where((note) => note.source == 'RDAP').single;
      expect(rdapNote.message, contains('unregistered'));
    });
  });
}
