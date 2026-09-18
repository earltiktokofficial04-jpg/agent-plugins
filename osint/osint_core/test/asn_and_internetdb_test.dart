import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

http.Response _txt(String value) => http.Response(
  jsonEncode({
    'Status': 0,
    'Answer': [
      {'name': 'x', 'type': 16, 'TTL': 60, 'data': '"$value"'},
    ],
  }),
  200,
);

http.Response get _nxdomain => http.Response(jsonEncode({'Status': 3}), 200);

AsnLookupService _asn(http.Response Function(String name) respond) =>
    AsnLookupService(
      dns: DnsOverHttpsService(
        client: MockClient(
          (request) async => respond(request.url.queryParameters['name']!),
        ),
      ),
    );

void main() {
  group('AsnLookupService', () {
    test('reverses an IPv4 address into the origin zone', () async {
      final queried = <String>[];
      final service = _asn((name) {
        queried.add(name);
        if (name.endsWith('origin.asn.cymru.com')) {
          return _txt('15169 | 8.8.8.0/24 | US | arin | 2023-12-28');
        }
        return _txt('15169 | US | arin | 2000-03-30 | GOOGLE - Google LLC, US');
      });

      final info = (await service.lookup(Target.parse('8.8.8.8'))).valueOrNull!;

      expect(queried.first, '8.8.8.8.origin.asn.cymru.com');
      expect(queried.last, 'AS15169.asn.cymru.com');
      expect(info.asn, 15169);
      expect(info.prefix, '8.8.8.0/24');
      expect(info.countryCode, 'US');
      expect(info.registry, 'arin');
      expect(info.allocated, DateTime.parse('2023-12-28'));
      expect(info.name, 'GOOGLE - Google LLC, US');
      expect(info.label, 'AS15169 — GOOGLE - Google LLC, US');
    });

    test('reverses a non-trivial IPv4 address correctly', () async {
      final queried = <String>[];
      final service = _asn((name) {
        queried.add(name);
        return _txt('64512 | 203.0.113.0/24 | MY | apnic | 2020-01-01');
      });

      await service.lookup(Target.parse('203.0.113.42'));
      expect(queried.first, '42.113.0.203.origin.asn.cymru.com');
    });

    test('expands IPv6 to reversed nibbles', () async {
      final queried = <String>[];
      final service = _asn((name) {
        queried.add(name);
        return _txt('15169 | 2001:4860::/32 | US | arin | 2005-03-14');
      });

      await service.lookup(Target.parse('2001:4860:4860::8888'));

      final query = queried.first;
      expect(query, endsWith('.origin6.asn.cymru.com'));
      // 32 nibbles, least significant first.
      final nibbles = query.split('.origin6').first.split('.');
      expect(nibbles, hasLength(32));
      expect(nibbles.first, '8');
      expect(nibbles.last, '2');
    });

    test('an unannounced address is empty, not a failure', () async {
      // Bogon and unrouted space genuinely has no origin record. Reporting
      // that as an error would bury a real finding in noise.
      final service = _asn((_) => _nxdomain);
      final result = await service.lookup(Target.parse('192.0.2.1'));
      expect(result, isA<SourceEmpty<AsnInfo>>());
      expect(
        (result as SourceEmpty<AsnInfo>).detail,
        contains('Not announced in BGP'),
      );
    });

    test('takes the most specific ASN when announcements overlap', () async {
      // Cymru returns several space-separated ASNs for overlapping origins.
      final service = _asn(
        (name) => name.contains('origin')
            ? _txt('64512 64513 | 203.0.113.0/24 | MY | apnic | 2020-01-01')
            : _nxdomain,
      );

      final info = (await service.lookup(
        Target.parse('203.0.113.1'),
      )).valueOrNull!;
      expect(info.asn, 64512);
    });

    test('a missing AS name does not fail the lookup', () async {
      // The ASN and prefix are the useful part; the org name is a bonus.
      final service = _asn(
        (name) => name.contains('origin')
            ? _txt('64512 | 203.0.113.0/24 | MY | apnic | 2020-01-01')
            : _nxdomain,
      );

      final info = (await service.lookup(
        Target.parse('203.0.113.1'),
      )).valueOrNull!;
      expect(info.name, isEmpty);
      expect(info.asn, 64512);
      expect(info.label, 'AS64512');
    });

    test('a resolver failure is reported as a failure', () async {
      final service = _asn((_) => http.Response('', 503));
      expect(
        await service.lookup(Target.parse('8.8.8.8')),
        isA<SourceFailure<AsnInfo>>(),
      );
    });

    test('a malformed record is reported rather than half-parsed', () async {
      final service = _asn((_) => _txt('not a cymru record'));
      final result = await service.lookup(Target.parse('8.8.8.8'));
      expect(result, isA<SourceFailure<AsnInfo>>());
      expect(
        (result as SourceFailure<AsnInfo>).message,
        contains('Unexpected origin record'),
      );
    });

    test('declines a non-IP target', () async {
      final service = _asn((_) => _nxdomain);
      expect(
        await service.lookup(Target.parse('example.com')),
        isA<SourceEmpty<AsnInfo>>(),
      );
    });
  });

  group('InternetDbService', () {
    test('parses ports, hostnames, CPEs, CVEs and tags', () async {
      final service = InternetDbService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ip': '45.33.32.156',
              'ports': [80, 22, 31337, 123],
              'hostnames': ['SCANME.nmap.org'],
              'cpes': ['cpe:/a:openbsd:openssh:6.6.1p1'],
              'vulns': ['CVE-2023-31122', 'CVE-2016-2183'],
              'tags': ['cloud'],
            }),
            200,
          ),
        ),
      );

      final host = (await service.host(
        Target.parse('45.33.32.156'),
      )).valueOrNull!;
      expect(host.ports, [22, 80, 123, 31337]);
      expect(host.hostnames, ['scanme.nmap.org']);
      expect(host.cpes, hasLength(1));
      expect(host.vulnerabilities, ['CVE-2016-2183', 'CVE-2023-31122']);
      expect(host.tags, ['cloud']);
    });

    test('an unobserved host is empty, not a failure', () async {
      final service = InternetDbService(
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(
        await service.host(Target.parse('192.0.2.1')),
        isA<SourceEmpty<InternetDbHost>>(),
      );
    });

    test('explains rate limiting in terms the user can act on', () async {
      final service = InternetDbService(
        client: MockClient((_) async => http.Response('', 429)),
      );
      final result = await service.host(Target.parse('8.8.8.8'));
      expect(
        (result as SourceFailure<InternetDbHost>).message,
        contains('one request per second'),
      );
    });

    test('a known host with nothing recorded reads as empty', () async {
      final service = InternetDbService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ip': '1.2.3.4',
              'ports': [],
              'hostnames': [],
              'cpes': [],
              'vulns': [],
              'tags': [],
            }),
            200,
          ),
        ),
      );
      expect(
        await service.host(Target.parse('1.2.3.4')),
        isA<SourceEmpty<InternetDbHost>>(),
      );
    });

    test('declines a non-IP target', () async {
      final service = InternetDbService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        await service.host(Target.parse('example.com')),
        isA<SourceEmpty<InternetDbHost>>(),
      );
    });
  });
}
