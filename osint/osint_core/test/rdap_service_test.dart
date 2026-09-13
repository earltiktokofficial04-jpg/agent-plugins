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

    test('does not call a domain unregistered when its TLD has no RDAP',
        () async {
      // .my publishes no RDAP service, so rdap.org 404s for every .my domain.
      // Reading that as "unregistered" would report live Malaysian company
      // domains as non-existent in a due-diligence check.
      final client = MockClient((request) async {
        if (request.url.toString().contains('rdap/dns.json')) {
          return http.Response(
            jsonEncode({
              'services': [
                [
                  ['com'],
                  ['https://rdap.verisign.test/'],
                ],
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      final result = await service.domain('mynic.my');
      final empty = result as SourceEmpty<DomainRegistration>;
      expect(empty.detail, contains('No RDAP service published for .my'));
      expect(empty.detail, isNot(contains('appears unregistered')));
    });

    test('does call it unregistered when its TLD does publish RDAP', () async {
      // .com is covered, so a 404 from Verisign really does mean the domain
      // is not registered.
      final client = MockClient((request) async {
        if (request.url.toString().contains('rdap/dns.json')) {
          return http.Response(
            jsonEncode({
              'services': [
                [
                  ['com'],
                  ['https://rdap.verisign.test/'],
                ],
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      final result = await service.domain('definitely-not-taken-xyzq.com');
      expect(
        (result as SourceEmpty<DomainRegistration>).detail,
        contains('appears unregistered'),
      );
    });

    test('hedges when TLD coverage is unknown', () async {
      // Without the bootstrap there is no way to tell the two cases apart, so
      // the wording must not commit to either.
      final service = RdapService(
        client: MockClient((_) async => http.Response('', 404)),
      );
      final result = await service.domain('something.my');
      final detail = (result as SourceEmpty<DomainRegistration>).detail;
      expect(detail, contains('may be unregistered'));
      expect(detail, contains('may publish no RDAP service'));
    });

    test('queries the TLD\'s own registry server when the bootstrap has one',
        () async {
      // The whole point of enumerating 590 registry servers is to ask them
      // directly; going through a redirector would make that count decorative.
      final requested = <String>[];
      final client = MockClient((request) async {
        final url = request.url.toString();
        requested.add(url);
        if (url.contains('rdap/dns.json')) {
          return http.Response(
            jsonEncode({
              'services': [
                [
                  ['my'],
                  ['https://rdap.mynic.test/rdap/'],
                ],
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'ldhName': 'example.my'}), 200);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      final registration = (await service.domain('example.my')).valueOrNull!;
      expect(
        requested.last,
        'https://rdap.mynic.test/rdap/domain/example.my',
        reason: 'trailing slash in the bootstrap entry must not double up',
      );
      expect(registration.registryServer, 'https://rdap.mynic.test/rdap/');
      expect(requested.any((url) => url.contains('rdap.org')), isFalse);
    });

    test('falls back to the redirector for a TLD with no RDAP server',
        () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        final url = request.url.toString();
        requested.add(url);
        if (url.contains('rdap/dns.json')) {
          return http.Response(
            jsonEncode({
              'services': [
                [
                  ['com'],
                  ['https://rdap.verisign.test/'],
                ],
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'ldhName': 'example.nowhere'}), 200);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      final registration =
          (await service.domain('example.nowhere')).valueOrNull!;
      expect(requested.last, 'https://rdap.org/domain/example.nowhere');
      expect(registration.registryServer, 'https://rdap.org');
    });

    test('falls back when the bootstrap itself cannot be fetched', () async {
      final client = MockClient((request) async {
        if (request.url.toString().contains('rdap/dns.json')) {
          return http.Response('', 503);
        }
        return http.Response(jsonEncode({'ldhName': 'example.com'}), 200);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      final result = await service.domain('example.com');
      expect(result, isA<SourceSuccess<DomainRegistration>>());
      expect(result.valueOrNull!.registryServer, 'https://rdap.org');
    });

    test('fetches the bootstrap once across many lookups', () async {
      // The table is ~300KB; re-fetching it per domain would be indefensible
      // on mobile data.
      var bootstrapFetches = 0;
      final client = MockClient((request) async {
        if (request.url.toString().contains('rdap/dns.json')) {
          bootstrapFetches++;
          return http.Response(
            jsonEncode({
              'services': [
                [
                  ['com'],
                  ['https://rdap.verisign.test/'],
                ],
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'ldhName': 'x.com'}), 200);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      await service.domain('a.com');
      await service.domain('b.com');
      await service.domain('c.com');
      expect(bootstrapFetches, 1);
    });

    test('a failed bootstrap is not retried on every lookup', () async {
      var bootstrapFetches = 0;
      final client = MockClient((request) async {
        if (request.url.toString().contains('rdap/dns.json')) {
          bootstrapFetches++;
          return http.Response('', 503);
        }
        return http.Response(jsonEncode({'ldhName': 'x.com'}), 200);
      });

      final service = RdapService(
        client: client,
        bootstrapRegistry: IanaRegistryService(client: client),
      );

      await service.domain('a.com');
      await service.domain('b.com');
      expect(bootstrapFetches, 1);
    });

    test('uses the redirector when no bootstrap registry is supplied',
        () async {
      final requested = <String>[];
      final service = RdapService(
        client: MockClient((request) async {
          requested.add(request.url.toString());
          return http.Response(jsonEncode({'ldhName': 'example.com'}), 200);
        }),
      );

      await service.domain('example.com');
      expect(requested, ['https://rdap.org/domain/example.com']);
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
