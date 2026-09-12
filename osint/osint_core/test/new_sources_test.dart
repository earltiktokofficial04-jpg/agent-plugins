import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('OtxService', () {
    OtxService service(Object body, [int status = 200]) => OtxService(
          client: MockClient(
            (_) async => http.Response(jsonEncode(body), status),
          ),
        );

    test('treats many pulses as malicious', () async {
      final result = await service({
        'pulse_info': {'count': 12},
      }).lookup(Target.parse('evil.test'));
      final verdict = result.valueOrNull!;
      expect(verdict.severity, IocSeverity.malicious);
      expect(verdict.detections, 12);
    });

    test('treats a handful of pulses as suspicious', () async {
      final result = await service({
        'pulse_info': {'count': 2},
      }).lookup(Target.parse('maybe.test'));
      expect(result.valueOrNull!.severity, IocSeverity.suspicious);
    });

    test('treats no pulses as clean', () async {
      final result = await service({
        'pulse_info': {'count': 0},
      }).lookup(Target.parse('fine.test'));
      expect(result.valueOrNull!.severity, IocSeverity.clean);
    });

    test('a whitelisted indicator stays clean despite many pulses', () async {
      // example.com really does carry 50 pulses while being whitelisted.
      // Without this, the tool would flag most of the best-known sites on the
      // internet as malicious.
      final result = await service({
        'pulse_info': {'count': 50},
        'validation': [
          {
            'source': 'whitelist',
            'name': 'Whitelisted domain',
            'message': 'Whitelisted domain example.com',
          },
        ],
      }).lookup(Target.parse('example.com'));

      final verdict = result.valueOrNull!;
      expect(verdict.severity, IocSeverity.clean);
      expect(verdict.detections, 50, reason: 'count is still reported');
      expect(verdict.details['Whitelisted'], contains('vouches'));
    });

    test('recognises Majestic and Akamai rankings as vouching', () async {
      final result = await service({
        'pulse_info': {'count': 30},
        'validation': [
          {'source': 'majestic', 'name': 'Listed in Majestic Million'},
        ],
      }).lookup(Target.parse('popular.test'));
      expect(result.valueOrNull!.severity, IocSeverity.clean);
    });

    test('carries network context through for an IP', () async {
      final result = await service({
        'pulse_info': {'count': 0},
        'asn': 'AS15169 google llc',
        'country_name': 'United States of America',
        'city': 'Mountain View',
      }).lookup(Target.parse('8.8.8.8'));
      final details = result.valueOrNull!.details;
      expect(details['ASN'], contains('AS15169'));
      expect(details['Country'], contains('United States'));
    });

    test('builds the right path per target kind', () async {
      final paths = <String>[];
      final otx = OtxService(
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200);
        }),
      );

      await otx.lookup(Target.parse('example.com'));
      await otx.lookup(Target.parse('8.8.8.8'));
      await otx.lookup(Target.parse('d41d8cd98f00b204e9800998ecf8427e'));

      expect(paths[0], contains('/indicators/domain/example.com/general'));
      expect(paths[1], contains('/indicators/IPv4/8.8.8.8/general'));
      expect(paths[2], contains('/indicators/file/'));
    });

    test('reports an unknown indicator as empty', () async {
      final result =
          await service(const {}, 404).lookup(Target.parse('example.com'));
      expect(result, isA<SourceEmpty<IocVerdict>>());
    });

    test('parses passive DNS history', () async {
      final otx = OtxService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'passive_dns': [
                {
                  'hostname': 'old.example.com',
                  'address': '203.0.113.5',
                  'record_type': 'A',
                  'first': '2024-01-01T00:00:00',
                  'last': '2025-06-01T00:00:00',
                },
              ],
            }),
            200,
          ),
        ),
      );

      final records =
          (await otx.passiveDns(Target.parse('example.com'))).valueOrNull!;
      expect(records, hasLength(1));
      expect(records.single.hostname, 'old.example.com');
      expect(records.single.firstSeen, DateTime.parse('2024-01-01'));
    });

    test('reports absent passive DNS as empty', () async {
      final otx = OtxService(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'passive_dns': []}), 200),
        ),
      );
      expect(
        await otx.passiveDns(Target.parse('example.com')),
        isA<SourceEmpty<List<PassiveDnsRecord>>>(),
      );
    });
  });

  group('HackerTargetService', () {
    test('parses the hostname,address CSV', () async {
      final service = HackerTargetService(
        client: MockClient(
          (_) async => http.Response(
            'a-api.anthropic.com,160.79.104.10\n'
            'A-CDN.anthropic.com,34.36.57.103\n',
            200,
          ),
        ),
      );

      final records =
          (await service.hostSearch('anthropic.com')).valueOrNull!;
      expect(records, hasLength(2));
      expect(records.first.hostname, 'a-api.anthropic.com');
      expect(records.first.address, '160.79.104.10');
      expect(records.last.hostname, 'a-cdn.anthropic.com',
          reason: 'hostnames are lowercased');
    });

    test('detects the quota message returned with a 200 status', () async {
      // The free tier reports its own limit in prose with HTTP 200; reading
      // only the status code would treat the message as data.
      final service = HackerTargetService(
        client: MockClient(
          (_) async => http.Response('API count exceeded - Increase Quota', 200),
        ),
      );
      final result = await service.hostSearch('example.com');
      expect(result, isA<SourceFailure<List<HostRecord>>>());
      expect(
        (result as SourceFailure<List<HostRecord>>).message,
        contains('quota'),
      );
    });

    test('reports an empty answer as empty', () async {
      final service = HackerTargetService(
        client: MockClient((_) async => http.Response('No records found', 200)),
      );
      expect(
        await service.hostSearch('example.com'),
        isA<SourceEmpty<List<HostRecord>>>(),
      );
    });

    test('parses reverse IP results', () async {
      final service = HackerTargetService(
        client: MockClient(
          (_) async => http.Response('one.test\ntwo.test\n', 200),
        ),
      );
      final records = (await service.reverseIp('1.2.3.4')).valueOrNull!;
      expect(records.map((r) => r.hostname), ['one.test', 'two.test']);
      expect(records.first.address, '1.2.3.4');
    });
  });

  group('WaybackService', () {
    test('parses the CDX response, skipping the header row', () async {
      final service = WaybackService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              ['original', 'timestamp', 'statuscode', 'mimetype'],
              [
                'http://example.com/admin',
                '20240115103000',
                '200',
                'text/html',
              ],
            ]),
            200,
          ),
        ),
      );

      final urls = (await service.urlsFor('example.com')).valueOrNull!;
      expect(urls, hasLength(1));
      expect(urls.single.url, 'http://example.com/admin');
      expect(urls.single.statusCode, '200');
      expect(urls.single.timestamp, DateTime.utc(2024, 1, 15, 10, 30));
    });

    test('reports no captures as empty', () async {
      final service = WaybackService(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(
        await service.urlsFor('example.com'),
        isA<SourceEmpty<List<ArchivedUrl>>>(),
      );
    });

    test('reports a blocked or failing index as a failure', () async {
      final service = WaybackService(
        client: MockClient((_) async => http.Response('blocked', 403)),
      );
      final result = await service.urlsFor('example.com');
      expect(result, isA<SourceFailure<List<ArchivedUrl>>>());
    });
  });
}
