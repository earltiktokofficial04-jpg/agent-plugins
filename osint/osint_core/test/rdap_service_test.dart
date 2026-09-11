import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('RdapService', () {
    test('parses events, registrar, nameservers and DNSSEC', () async {
      final service = RdapService(
        client: MockClient((request) async {
          expect(request.url.path, '/domain/example.com');
          return http.Response(
            jsonEncode({
              'ldhName': 'EXAMPLE.COM',
              'status': ['client transfer prohibited'],
              'events': [
                {'eventAction': 'registration', 'eventDate': '1995-08-14T04:00:00Z'},
                {'eventAction': 'expiration', 'eventDate': '2027-08-13T04:00:00Z'},
                {'eventAction': 'last changed', 'eventDate': '2026-08-14T07:01:44Z'},
              ],
              'nameservers': [
                {'ldhName': 'A.IANA-SERVERS.NET'},
                {'ldhName': 'B.IANA-SERVERS.NET'},
              ],
              'secureDNS': {'delegationSigned': true},
              'entities': [
                {
                  'roles': ['registrar'],
                  'vcardArray': [
                    'vcard',
                    [
                      ['version', {}, 'text', '4.0'],
                      ['fn', {}, 'text', 'RESERVED-Internet Assigned Numbers Authority'],
                    ],
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.domain('example.com');
      final registration = result.valueOrNull!;
      expect(registration.domain, 'example.com');
      expect(registration.registrar, contains('Internet Assigned Numbers'));
      expect(registration.registered, DateTime.utc(1995, 8, 14, 4));
      expect(registration.expires, DateTime.utc(2027, 8, 13, 4));
      expect(registration.nameservers, ['a.iana-servers.net', 'b.iana-servers.net']);
      expect(registration.dnssecSigned, isTrue);
      expect(registration.statuses, ['client transfer prohibited']);
    });

    test('treats a 404 as an unregistered domain, not an error', () async {
      final service = RdapService(
        client: MockClient((_) async => http.Response('', 404)),
      );
      final result = await service.domain('nope.example');
      expect(result, isA<SourceEmpty<DomainRegistration>>());
      expect(
        (result as SourceEmpty<DomainRegistration>).detail,
        contains('unregistered'),
      );
    });

    test('survives a record with no registrar entity', () async {
      final service = RdapService(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'ldhName': 'x.com'}), 200),
        ),
      );
      final registration = (await service.domain('x.com')).valueOrNull!;
      expect(registration.registrar, '');
      expect(registration.registered, isNull);
      expect(registration.nameservers, isEmpty);
      expect(registration.dnssecSigned, isFalse);
    });

    test('ageAt measures registration age from the injected clock', () {
      final registration = DomainRegistration(
        domain: 'example.com',
        registered: DateTime.utc(2026, 1, 1),
      );
      expect(
        registration.ageAt(DateTime.utc(2026, 1, 31))!.inDays,
        30,
      );
      expect(
        const DomainRegistration(domain: 'x.com').ageAt(DateTime.utc(2026)),
        isNull,
      );
    });
  });
}
