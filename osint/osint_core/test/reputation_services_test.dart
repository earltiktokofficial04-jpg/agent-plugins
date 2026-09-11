import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

http.Client _json(Object body, [int status = 200]) =>
    MockClient((_) async => http.Response(jsonEncode(body), status));

Map<String, Object> _vtBody({
  int malicious = 0,
  int suspicious = 0,
  int harmless = 0,
  int undetected = 0,
}) =>
    {
      'data': {
        'attributes': {
          'last_analysis_stats': {
            'malicious': malicious,
            'suspicious': suspicious,
            'harmless': harmless,
            'undetected': undetected,
          },
        },
      },
    };

void main() {
  final keys = InMemoryApiKeyProvider({
    ApiKeySource.virusTotal: 'vt-key',
    ApiKeySource.abuseIpdb: 'abuse-key',
    ApiKeySource.shodan: 'shodan-key',
  });

  group('VirusTotalService', () {
    test('flags two or more detections as malicious', () async {
      final service = VirusTotalService(
        keys: keys,
        client: _json(_vtBody(malicious: 5, harmless: 60)),
      );
      final verdict =
          (await service.lookup(Target.parse('evil.example'))).valueOrNull!;
      expect(verdict.severity, IocSeverity.malicious);
      expect(verdict.detections, 5);
      expect(verdict.totalEngines, 65);
    });

    test('downgrades a single detection to suspicious', () async {
      // Lone hits from low-quality engines are the dominant false-positive
      // source in VirusTotal, so one detection must not read as malicious.
      final service = VirusTotalService(
        keys: keys,
        client: _json(_vtBody(malicious: 1, harmless: 70)),
      );
      final verdict =
          (await service.lookup(Target.parse('example.com'))).valueOrNull!;
      expect(verdict.severity, IocSeverity.suspicious);
    });

    test('reports clean when engines responded with no detections', () async {
      final service = VirusTotalService(
        keys: keys,
        client: _json(_vtBody(harmless: 70, undetected: 4)),
      );
      final verdict =
          (await service.lookup(Target.parse('example.com'))).valueOrNull!;
      expect(verdict.severity, IocSeverity.clean);
    });

    test('reports unknown when no engine responded at all', () async {
      final service = VirusTotalService(keys: keys, client: _json(_vtBody()));
      final verdict =
          (await service.lookup(Target.parse('example.com'))).valueOrNull!;
      expect(verdict.severity, IocSeverity.unknown);
    });

    test('builds the right path for each target kind', () async {
      final paths = <String>[];
      final service = VirusTotalService(
        keys: keys,
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(jsonEncode(_vtBody(harmless: 1)), 200);
        }),
      );

      await service.lookup(Target.parse('example.com'));
      await service.lookup(Target.parse('8.8.8.8'));
      await service.lookup(Target.parse('d41d8cd98f00b204e9800998ecf8427e'));

      expect(paths[0], endsWith('/domains/example.com'));
      expect(paths[1], endsWith('/ip_addresses/8.8.8.8'));
      expect(paths[2], endsWith('/files/d41d8cd98f00b204e9800998ecf8427e'));
    });

    test('signals a missing key so the UI can offer settings', () async {
      final service = VirusTotalService(
        keys: InMemoryApiKeyProvider(),
        client: _json(_vtBody()),
      );
      final result = await service.lookup(Target.parse('example.com'));
      expect(result, isA<SourceFailure<IocVerdict>>());
      expect((result as SourceFailure<IocVerdict>).needsApiKey, isTrue);
    });

    test('signals a rejected key as a key problem too', () async {
      final service = VirusTotalService(
        keys: keys,
        client: MockClient((_) async => http.Response('', 401)),
      );
      final result = await service.lookup(Target.parse('example.com'));
      expect((result as SourceFailure<IocVerdict>).needsApiKey, isTrue);
    });

    test('explains a 429 in terms of the free-tier rate limit', () async {
      final service = VirusTotalService(
        keys: keys,
        client: MockClient((_) async => http.Response('', 429)),
      );
      final result = await service.lookup(Target.parse('example.com'));
      expect(
        (result as SourceFailure<IocVerdict>).message,
        contains('4 lookups/minute'),
      );
    });

    test('treats an unseen indicator as empty', () async {
      final service = VirusTotalService(
        keys: keys,
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(
        await service.lookup(Target.parse('example.com')),
        isA<SourceEmpty<IocVerdict>>(),
      );
    });

    test('declines a target kind it cannot look up', () async {
      final service = VirusTotalService(keys: keys, client: _json(_vtBody()));
      expect(
        await service.lookup(Target.parse('not a target')),
        isA<SourceEmpty<IocVerdict>>(),
      );
    });
  });

  group('AbuseIpdbService', () {
    Map<String, Object> body(int score, {int reports = 0}) => {
          'data': {
            'abuseConfidenceScore': score,
            'totalReports': reports,
            'countryCode': 'MY',
            'isp': 'Example ISP',
            'usageType': 'Data Center/Web Hosting/Transit',
          },
        };

    test('maps the confidence score onto severity bands', () async {
      Future<IocSeverity> severityFor(int score) async {
        final service =
            AbuseIpdbService(keys: keys, client: _json(body(score)));
        final result = await service.check(Target.parse('1.2.3.4'));
        return result.valueOrNull!.severity;
      }

      expect(await severityFor(0), IocSeverity.clean);
      expect(await severityFor(24), IocSeverity.clean);
      expect(await severityFor(25), IocSeverity.suspicious);
      expect(await severityFor(74), IocSeverity.suspicious);
      expect(await severityFor(75), IocSeverity.malicious);
      expect(await severityFor(100), IocSeverity.malicious);
    });

    test('carries the score, report count and context through', () async {
      final service = AbuseIpdbService(
        keys: keys,
        client: _json(body(88, reports: 42)),
      );
      final verdict =
          (await service.check(Target.parse('1.2.3.4'))).valueOrNull!;
      expect(verdict.score, 88);
      expect(verdict.detections, 42);
      expect(verdict.details['Country'], 'MY');
      expect(verdict.details['ISP'], 'Example ISP');
    });

    test('declines a non-IP target', () async {
      final service = AbuseIpdbService(keys: keys, client: _json(body(0)));
      expect(
        await service.check(Target.parse('example.com')),
        isA<SourceEmpty<IocVerdict>>(),
      );
    });
  });

  group('ShodanHostService', () {
    test('parses ports, banners and CVE leads', () async {
      final service = ShodanHostService(
        keys: keys,
        client: _json({
          'ip_str': '1.2.3.4',
          'ports': [443, 22, 80],
          'hostnames': ['Host.Example.COM'],
          'org': 'Example Cloud',
          'os': null,
          'vulns': ['CVE-2026-1000', 'CVE-2025-0001'],
          'data': [
            {
              'port': 443,
              'transport': 'tcp',
              'product': 'nginx',
              'version': '1.24.0',
            },
            {'port': 22, 'transport': 'tcp', 'product': 'OpenSSH'},
          ],
          'last_update': '2026-09-01T00:00:00.000000',
        }),
      );

      final host = (await service.host(Target.parse('1.2.3.4'))).valueOrNull!;
      expect(host.ports, [22, 80, 443]);
      expect(host.hostnames, ['host.example.com']);
      expect(host.organisation, 'Example Cloud');
      expect(host.vulnerabilities, ['CVE-2025-0001', 'CVE-2026-1000']);
      expect(host.services.first.port, 22);
      expect(host.services.last.label, '443/tcp nginx 1.24.0');
    });

    test('reports an unknown host as empty', () async {
      final service = ShodanHostService(
        keys: keys,
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(
        await service.host(Target.parse('1.2.3.4')),
        isA<SourceEmpty<ShodanHost>>(),
      );
    });

    test('explains a plan restriction distinctly from a bad key', () async {
      final service = ShodanHostService(
        keys: keys,
        client: MockClient((_) async => http.Response('', 403)),
      );
      final result = await service.host(Target.parse('1.2.3.4'));
      final failure = result as SourceFailure<ShodanHost>;
      expect(failure.message, contains('plan'));
      expect(failure.needsApiKey, isFalse);
    });
  });
}
