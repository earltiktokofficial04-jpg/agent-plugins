import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

http.Response _answer(String name, int type, String data) => http.Response(
      jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': name, 'type': type, 'TTL': 60, 'data': data},
        ],
      }),
      200,
    );

http.Response get _nxdomain => http.Response(jsonEncode({'Status': 3}), 200);

/// Wires a sweep against canned registry lists and a canned resolver.
TldSweepRepository _repository({
  required http.Response Function(String name, String type) dns,
  List<String> tlds = const ['com', 'net', 'xyz', 'tk'],
  List<String> suffixes = const ['com', 'net', 'xyz', 'tk', 'com.my', 'co.uk'],
  bool registryFails = false,
}) {
  final client = MockClient((request) async {
    final url = request.url.toString();
    if (url.contains('tlds-alpha')) {
      return registryFails
          ? http.Response('', 503)
          : http.Response('# v\n${tlds.join('\n').toUpperCase()}\n', 200);
    }
    if (url.contains('public_suffix')) {
      return registryFails
          ? http.Response('', 503)
          : http.Response('// x\n${suffixes.join('\n')}\n', 200);
    }
    final params = request.url.queryParameters;
    return dns(params['name']!, params['type']!);
  });

  return TldSweepRepository(
    dns: DnsOverHttpsService(client: client),
    registry: IanaRegistryService(client: client),
  );
}

void main() {
  group('TldSweepRepository namespaces', () {
    test('focused breadth uses the bundled list without a fetch', () async {
      final repository = TldSweepRepository(
        dns: DnsOverHttpsService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
        registry: IanaRegistryService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
      );
      final namespaces =
          await repository.namespacesFor(SweepBreadth.focused);
      expect(namespaces, TyposquatGenerator.defaultTlds);
    });

    test('fetches and caches the TLD list', () async {
      var fetches = 0;
      final client = MockClient((request) async {
        if (request.url.toString().contains('tlds-alpha')) {
          fetches++;
          return http.Response('# v\nCOM\nNET\n', 200);
        }
        return _nxdomain;
      });
      final repository = TldSweepRepository(
        dns: DnsOverHttpsService(client: client),
        registry: IanaRegistryService(client: client),
      );

      expect(await repository.namespacesFor(SweepBreadth.allTlds),
          ['com', 'net']);
      await repository.namespacesFor(SweepBreadth.allTlds);
      expect(fetches, 1, reason: 'the list should be fetched once');
    });

    test('returns empty when the registry is unreachable', () async {
      final repository = _repository(dns: (_, __) => _nxdomain, registryFails: true);
      expect(await repository.namespacesFor(SweepBreadth.allTlds), isEmpty);
    });
  });

  group('TldSweepRepository sweep', () {
    test('varies the suffix and keeps the label fixed', () async {
      final checked = <String>{};
      final repository = _repository(
        dns: (name, _) {
          checked.add(name);
          return _nxdomain;
        },
      );

      await repository.sweep('acme.com', breadth: SweepBreadth.allTlds);

      expect(checked, contains('acme.net'));
      expect(checked, contains('acme.xyz'));
      expect(checked, contains('acme.tk'));
      // The brand's own namespace is not a squat against itself.
      expect(checked, isNot(contains('acme.com')));
    });

    test('sweeps second-level namespaces at full breadth', () async {
      final checked = <String>{};
      final repository = _repository(
        dns: (name, _) {
          checked.add(name);
          return _nxdomain;
        },
      );

      await repository.sweep('acme.com', breadth: SweepBreadth.allSuffixes);

      expect(checked, contains('acme.com.my'));
      expect(checked, contains('acme.co.uk'));
    });

    test('reports a registered look-alike with its addresses', () async {
      final repository = _repository(
        dns: (name, type) {
          if (name == 'acme.tk' && type == '1') {
            return _answer(name, 1, '203.0.113.9');
          }
          if (name == 'acme.tk' && type == '15') {
            return _answer(name, 15, '10 mail.acme.tk');
          }
          return _nxdomain;
        },
      );

      final report =
          await repository.sweep('acme.com', breadth: SweepBreadth.allTlds);

      final hit = report.findings.single;
      expect(hit.candidate.domain, 'acme.tk');
      expect(hit.addresses, ['203.0.113.9']);
      expect(hit.hasMailExchanger, isTrue);
      expect(hit.isActionable, isTrue);
    });

    test('never reports a failed lookup as unregistered', () async {
      final repository = _repository(
        dns: (_, __) => http.Response('rate limited', 429),
      );
      final report =
          await repository.sweep('acme.com', breadth: SweepBreadth.allTlds);
      expect(report.findings, isEmpty);
      expect(report.candidatesChecked, 3);
    });

    test('honours the limit and reports both counts', () async {
      final repository = _repository(
        dns: (_, __) => _nxdomain,
        tlds: const ['a', 'b', 'c', 'd', 'e', 'f', 'com'],
      );
      final report = await repository.sweep(
        'acme.com',
        breadth: SweepBreadth.allTlds,
        limit: 2,
      );
      expect(report.candidatesGenerated, 6);
      expect(report.candidatesChecked, 2);
    });

    test('reports progress for every namespace checked', () async {
      final progress = <int>[];
      final repository = _repository(dns: (_, __) => _nxdomain);
      await repository.sweep(
        'acme.com',
        breadth: SweepBreadth.allTlds,
        concurrency: 2,
        onProgress: (checked, _) => progress.add(checked),
      );
      expect(progress, hasLength(3));
      expect(progress.last, 3);
    });

    test('reports a malformed brand domain', () async {
      final repository = _repository(dns: (_, __) => _nxdomain);
      final report = await repository.sweep('localhost');
      expect(report.findings, isEmpty);
      expect(report.notes.single.ok, isFalse);
      expect(report.notes.single.message, contains('brand label'));
    });

    test('reports an unreachable namespace registry distinctly', () async {
      // "The list could not be fetched" must not look like "nothing found".
      final repository =
          _repository(dns: (_, __) => _nxdomain, registryFails: true);
      final report =
          await repository.sweep('acme.com', breadth: SweepBreadth.allTlds);
      expect(report.notes.single.ok, isFalse);
      expect(report.notes.single.message, contains('could not be fetched'));
    });
  });
}
