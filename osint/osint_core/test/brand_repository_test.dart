import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

/// Builds a DoH service whose answers are decided per (name, type).
DnsOverHttpsService _dns(
  http.Response Function(String name, String type) respond,
) =>
    DnsOverHttpsService(
      client: MockClient((request) async {
        final params = request.url.queryParameters;
        return respond(params['name']!, params['type']!);
      }),
    );

http.Response _answer(String name, int type, String data) => http.Response(
      jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': name, 'type': type, 'TTL': 60, 'data': data},
        ],
      }),
      200,
    );

http.Response get _nxdomain =>
    http.Response(jsonEncode({'Status': 3}), 200);

void main() {
  group('BrandRepository', () {
    test('generates candidates without any network access', () {
      // The MockClient throws, so any request would fail the test outright.
      final repository = BrandRepository(
        dns: DnsOverHttpsService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
      );
      final candidates = repository.candidatesFor('example.com');
      expect(candidates, isNotEmpty);
      expect(
        candidates.every(
          (c) => BrandRepository.highSignalTechniques.contains(c.technique),
        ),
        isTrue,
      );
    });

    test('reports a resolving look-alike as registered and actionable',
        () async {
      final repository = BrandRepository(
        dns: _dns((name, type) {
          if (name == 'exarnple.com') {
            if (type == '1') return _answer(name, 1, '203.0.113.10');
            if (type == '15') return _answer(name, 15, '10 mail.evil.test');
          }
          return _nxdomain;
        }),
      );

      final report = await repository.sweep('example.com', limit: 400);
      final hit = report.findings
          .where((f) => f.candidate.domain == 'exarnple.com')
          .single;

      expect(hit.isRegistered, isTrue);
      expect(hit.addresses, ['203.0.113.10']);
      expect(hit.hasMailExchanger, isTrue);
      expect(hit.isActionable, isTrue);
      expect(report.actionable, contains(hit));
    });

    test('treats a parked domain with only NS records as registered',
        () async {
      final repository = BrandRepository(
        dns: _dns((name, type) {
          if (name == 'exarnple.com' && type == '2') {
            return _answer(name, 2, 'ns1.parking.test');
          }
          return _nxdomain;
        }),
      );

      final report = await repository.sweep('example.com', limit: 400);
      final hit = report.findings
          .where((f) => f.candidate.domain == 'exarnple.com')
          .single;

      expect(hit.isRegistered, isTrue);
      expect(hit.addresses, isEmpty);
      expect(hit.nameservers, ['ns1.parking.test']);
      // Registered but neither resolving nor mail-capable: worth listing, not
      // worth waking someone up for.
      expect(hit.isActionable, isFalse);
    });

    test('never reports a failed lookup as an unregistered domain', () async {
      // This is the safety property of the whole sweep: turning a rate limit
      // into a false all-clear is the most damaging wrong answer possible.
      final repository = BrandRepository(
        dns: _dns((_, __) => http.Response('rate limited', 429)),
      );

      final report = await repository.sweep('example.com', limit: 20);
      expect(report.findings, isEmpty);
      expect(report.candidatesChecked, 20);
    });

    test('excludes unregistered candidates from the findings', () async {
      final repository = BrandRepository(
        dns: _dns((_, __) => _nxdomain),
      );
      final report = await repository.sweep('example.com', limit: 30);
      expect(report.findings, isEmpty);
      expect(report.candidatesGenerated, greaterThan(30));
      expect(report.candidatesChecked, 30);
    });

    test('honours the candidate limit', () async {
      var lookups = 0;
      final repository = BrandRepository(
        dns: _dns((_, __) {
          lookups++;
          return _nxdomain;
        }),
      );

      await repository.sweep('example.com', limit: 5);
      // Each unregistered candidate costs an A lookup then an NS lookup.
      expect(lookups, 10);
    });

    test('reports progress for every candidate checked', () async {
      final progress = <int>[];
      final repository = BrandRepository(dns: _dns((_, __) => _nxdomain));

      await repository.sweep(
        'example.com',
        limit: 7,
        concurrency: 2,
        onProgress: (checked, total) {
          progress.add(checked);
          expect(total, 7);
        },
      );

      expect(progress, hasLength(7));
      expect(progress.last, 7);
    });

    test('sorts actionable findings ahead of merely registered ones',
        () async {
      final repository = BrandRepository(
        dns: _dns((name, type) {
          // A parked hit that sorts alphabetically first, and a live hit that
          // sorts later, so ordering cannot pass by accident.
          if (name == 'eaxmple.com' && type == '2') {
            return _answer(name, 2, 'ns1.parking.test');
          }
          if (name == 'exarnple.com' && type == '1') {
            return _answer(name, 1, '203.0.113.10');
          }
          return _nxdomain;
        }),
      );

      final report = await repository.sweep('example.com', limit: 400);
      expect(report.findings.length, greaterThanOrEqualTo(2));
      expect(report.findings.first.candidate.domain, 'exarnple.com');
      expect(report.findings.first.isActionable, isTrue);
    });

    test('reports a malformed brand domain instead of sweeping', () async {
      final repository = BrandRepository(
        dns: DnsOverHttpsService(
          client: MockClient((_) async => throw StateError('no network')),
        ),
      );
      final report = await repository.sweep('localhost');
      expect(report.findings, isEmpty);
      expect(report.notes.single.ok, isFalse);
      expect(report.notes.single.message, contains('candidates'));
    });
  });
}
