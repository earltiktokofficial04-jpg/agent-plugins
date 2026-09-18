import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('DnsOverHttpsService', () {
    test('parses an answer section into records', () async {
      final service = DnsOverHttpsService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['name'], 'example.com');
          expect(request.url.queryParameters['type'], '1');
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'name': 'example.com',
                  'type': 1,
                  'TTL': 300,
                  'data': '93.184.216.34',
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.resolve('example.com', DnsRecordType.a);
      expect(result, isA<SourceSuccess<List<DnsRecord>>>());
      final records = result.valueOrNull!;
      expect(records, hasLength(1));
      expect(records.single.data, '93.184.216.34');
      expect(records.single.type, DnsRecordType.a);
      expect(records.single.ttl, 300);
    });

    test('strips the quotes DNS puts around TXT values', () async {
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'name': 'example.com',
                  'type': 16,
                  'TTL': 60,
                  'data': '"v=spf1 include:_spf.example.com ~all"',
                },
              ],
            }),
            200,
          ),
        ),
      );

      final result = await service.resolve('example.com', DnsRecordType.txt);
      expect(
        result.valueOrNull!.single.data,
        'v=spf1 include:_spf.example.com ~all',
      );
    });

    test('reports NXDOMAIN as empty, not as a failure', () async {
      // This distinction is what lets the brand sweep tell "unregistered"
      // apart from "the lookup broke".
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'Status': 3}), 200),
        ),
      );

      final result = await service.resolve('nope.example', DnsRecordType.a);
      expect(result, isA<SourceEmpty<List<DnsRecord>>>());
      expect((result as SourceEmpty<List<DnsRecord>>).detail, 'NXDOMAIN');
    });

    test('reports an empty answer section as empty', () async {
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200),
        ),
      );

      final result = await service.resolve('example.com', DnsRecordType.mx);
      expect(result, isA<SourceEmpty<List<DnsRecord>>>());
    });

    test('reports a non-200 response as a failure', () async {
      final service = DnsOverHttpsService(
        client: MockClient((_) async => http.Response('nope', 503)),
      );

      final result = await service.resolve('example.com', DnsRecordType.a);
      expect(result, isA<SourceFailure<List<DnsRecord>>>());
      expect(
        (result as SourceFailure<List<DnsRecord>>).message,
        contains('503'),
      );
    });

    test('reports a thrown transport error as a failure', () async {
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async =>
              throw http.ClientException('simulated transport failure'),
        ),
      );

      final result = await service.resolve('example.com', DnsRecordType.a);
      expect(result, isA<SourceFailure<List<DnsRecord>>>());
    });

    test('skips record types the engine does not model', () async {
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {'name': 'example.com', 'type': 99, 'TTL': 1, 'data': 'x'},
              ],
            }),
            200,
          ),
        ),
      );

      final result = await service.resolve('example.com', DnsRecordType.a);
      expect(result, isA<SourceEmpty<List<DnsRecord>>>());
    });

    test('returns only the record type that was queried', () async {
      // A resolver answers an A query for a CNAME'd host with the CNAME AND
      // the final A. Keeping both would report the CNAME target as an
      // address — verified against the real resolver: an A query for
      // www.github.com answers with "github.com." (type 5) and 140.82.112.4.
      final service = DnsOverHttpsService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'name': 'www.example.com',
                  'type': 5,
                  'TTL': 60,
                  'data': 'example.com.',
                },
                {
                  'name': 'example.com',
                  'type': 1,
                  'TTL': 60,
                  'data': '140.82.112.4',
                },
              ],
            }),
            200,
          ),
        ),
      );

      final records = (await service.resolve(
        'www.example.com',
        DnsRecordType.a,
      )).valueOrNull!;
      expect(records, hasLength(1));
      expect(records.single.type, DnsRecordType.a);
      expect(records.single.data, '140.82.112.4');
    });

    test(
      'a CNAME-only answer to an A query is empty, not a false address',
      () async {
        final service = DnsOverHttpsService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'Status': 0,
                'Answer': [
                  {
                    'name': 'www.example.com',
                    'type': 5,
                    'TTL': 60,
                    'data': 'target.example.net.',
                  },
                ],
              }),
              200,
            ),
          ),
        );

        expect(
          await service.resolve('www.example.com', DnsRecordType.a),
          isA<SourceEmpty<List<DnsRecord>>>(),
        );
      },
    );

    test('resolveAll fails when every lookup failed', () async {
      // The invariant the whole engine turns on. A flattened list cannot
      // express the difference between "the resolver is down" and "this
      // domain publishes nothing", so resolveAll must.
      final service = DnsOverHttpsService(
        client: MockClient((_) async => http.Response('', 503)),
      );

      final result = await service.resolveAll('example.com', [
        DnsRecordType.a,
        DnsRecordType.mx,
      ]);
      expect(result, isA<SourceFailure<List<DnsRecord>>>());
      expect(
        (result as SourceFailure<List<DnsRecord>>).message,
        contains('Every lookup failed'),
      );
    });

    test(
      'resolveAll is empty when every lookup answered with nothing',
      () async {
        final service = DnsOverHttpsService(
          client: MockClient(
            (_) async => http.Response(jsonEncode({'Status': 3}), 200),
          ),
        );

        final result = await service.resolveAll('example.com', [
          DnsRecordType.a,
          DnsRecordType.mx,
        ]);
        expect(result, isA<SourceEmpty<List<DnsRecord>>>());
      },
    );

    test('resolveAll succeeds on a partial answer', () async {
      // One dead record type must not discard the others.
      final service = DnsOverHttpsService(
        client: MockClient((request) async {
          if (request.url.queryParameters['type'] == '15') {
            return http.Response('', 500);
          }
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'name': 'example.com',
                  'type': 1,
                  'TTL': 60,
                  'data': '1.2.3.4',
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.resolveAll('example.com', [
        DnsRecordType.a,
        DnsRecordType.mx,
      ]);
      expect(result, isA<SourceSuccess<List<DnsRecord>>>());
      expect(result.valueOrNull, hasLength(1));
    });

    test('resolveAll flattens successes and drops failures', () async {
      final service = DnsOverHttpsService(
        client: MockClient((request) async {
          final type = request.url.queryParameters['type'];
          if (type == '15') return http.Response('boom', 500);
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {'name': 'example.com', 'type': 1, 'TTL': 1, 'data': '1.2.3.4'},
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.resolveAll('example.com', [
        DnsRecordType.a,
        DnsRecordType.mx,
      ]);
      final records = result.valueOrNull!;
      expect(records, hasLength(1));
      expect(records.single.data, '1.2.3.4');
    });
  });
}
