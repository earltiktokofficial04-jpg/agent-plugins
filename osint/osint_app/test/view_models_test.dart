import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/core/scan_status.dart';
import 'package:osint_app/ui/features/brand/view_models/brand_view_model.dart';
import 'package:osint_app/ui/features/due_diligence/view_models/due_diligence_view_model.dart';
import 'package:osint_app/ui/features/recon/view_models/recon_view_model.dart';
import 'package:osint_app/ui/features/threat_intel/view_models/threat_intel_view_model.dart';
import 'package:osint_core/osint_core.dart';

http.Client _nxdomain() => MockClient(
      (request) async => request.url.host.contains('crt.sh')
          ? http.Response('[]', 200)
          : http.Response(jsonEncode({'Status': 3}), 200),
    );

BrandViewModel _brandViewModel(http.Client client) {
  final dns = DnsOverHttpsService(client: client);
  return BrandViewModel(
    repository: BrandRepository(dns: dns),
    namespaceRepository: TldSweepRepository(
      dns: dns,
      registry: IanaRegistryService(client: client),
    ),
  );
}

ReconRepository _reconRepository(http.Client client) => ReconRepository(
      dns: DnsOverHttpsService(client: client),
      crtSh: CrtShService(client: client),
    );

void main() {
  group('ReconViewModel', () {
    test('starts idle', () {
      final viewModel =
          ReconViewModel(repository: _reconRepository(_nxdomain()));
      expect(viewModel.status, ScanStatus.idle);
      expect(viewModel.report, isNull);
      expect(viewModel.isBusy, isFalse);
    });

    test('rejects a non-domain target without making a request', () async {
      final viewModel = ReconViewModel(
        repository: _reconRepository(
          MockClient((_) async => throw StateError('no request expected')),
        ),
      );

      await viewModel.scan('8.8.8.8');

      expect(viewModel.status, ScanStatus.rejected);
      expect(viewModel.rejection, contains('domain'));
      expect(viewModel.report, isNull);
    });

    test('rejects unparseable input', () async {
      final viewModel = ReconViewModel(
        repository: _reconRepository(
          MockClient((_) async => throw StateError('no request expected')),
        ),
      );
      await viewModel.scan('   ');
      expect(viewModel.status, ScanStatus.rejected);
    });

    test('produces a report and notifies listeners', () async {
      final viewModel =
          ReconViewModel(repository: _reconRepository(_nxdomain()));
      var notifications = 0;
      viewModel.addListener(() => notifications++);

      await viewModel.scan('example.com');

      expect(viewModel.status, ScanStatus.done);
      expect(viewModel.report, isNotNull);
      // One notification for entering the running state, one for the result.
      expect(notifications, greaterThanOrEqualTo(2));
    });

    test('toggling host enrichment notifies only on a real change', () {
      final viewModel =
          ReconViewModel(repository: _reconRepository(_nxdomain()));
      var notifications = 0;
      viewModel.addListener(() => notifications++);

      viewModel.setEnrichHosts(false);
      expect(notifications, 0);

      viewModel.setEnrichHosts(true);
      expect(viewModel.enrichHosts, isTrue);
      expect(notifications, 1);
    });
  });

  group('ThreatIntelViewModel', () {
    ThreatIntelRepository repository(http.Client client) {
      final keys = InMemoryApiKeyProvider({ApiKeySource.virusTotal: 'k'});
      return ThreatIntelRepository(
        virusTotal: VirusTotalService(keys: keys, client: client),
        abuseIpdb: AbuseIpdbService(keys: keys, client: client),
      );
    }

    test('rejects input that is not an indicator', () async {
      final viewModel = ThreatIntelViewModel(
        repository: repository(
          MockClient((_) async => throw StateError('no request expected')),
        ),
      );
      await viewModel.enrich('this is not an indicator');
      expect(viewModel.status, ScanStatus.rejected);
      expect(viewModel.rejection, contains('hash'));
    });

    test('records the detected target kind for a hash', () async {
      final viewModel = ThreatIntelViewModel(
        repository: repository(
          MockClient((_) async => http.Response('', 404)),
        ),
      );
      await viewModel.enrich('d41d8cd98f00b204e9800998ecf8427e');
      expect(viewModel.target!.kind, TargetKind.md5);
      expect(viewModel.status, ScanStatus.done);
      expect(viewModel.result!.report.hasOpinion, isFalse);
    });
  });

  group('BrandViewModel', () {
    test('previews the candidate count with no network access', () {
      final viewModel = _brandViewModel(
        MockClient((_) async => throw StateError('no network')),
      );
      expect(viewModel.previewCount('example.com'), greaterThan(50));
      expect(viewModel.previewCount('not a domain'), 0);
    });

    test('reports progress as a fraction while sweeping', () async {
      final viewModel = _brandViewModel(_nxdomain());
      expect(viewModel.progress, isNull);

      viewModel.setLimit(25);
      await viewModel.sweep('example.com');

      expect(viewModel.status, ScanStatus.done);
      expect(viewModel.progress, 1.0);
      expect(viewModel.report!.candidatesChecked, 25);
    });

    test('rejects a malformed brand domain', () async {
      final viewModel = _brandViewModel(
        MockClient((_) async => throw StateError('no network')),
      );
      await viewModel.sweep('localhost');
      expect(viewModel.status, ScanStatus.rejected);
    });
  });

  group('DueDiligenceViewModel', () {
    DueDiligenceRepository repository(DateTime registered) {
      final client = MockClient((request) async {
        if (request.url.host.contains('rdap')) {
          return http.Response(
            jsonEncode({
              'ldhName': 'example.com',
              'events': [
                {
                  'eventAction': 'registration',
                  'eventDate': registered.toIso8601String(),
                },
              ],
            }),
            200,
          );
        }
        if (request.url.host.contains('crt.sh')) {
          return http.Response('[]', 200);
        }
        return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
      });
      return DueDiligenceRepository(
        rdap: RdapService(client: client),
        dns: DnsOverHttpsService(client: client),
        crtSh: CrtShService(client: client),
      );
    }

    test('flags a domain registered inside 90 days', () async {
      final now = DateTime.utc(2026, 9, 11);
      final viewModel = DueDiligenceViewModel(
        repository: repository(DateTime.utc(2026, 8, 1)),
        now: () => now,
      );

      await viewModel.profile('example.com');

      expect(viewModel.registrationAge!.inDays, 41);
      expect(viewModel.isRecentlyRegistered, isTrue);
    });

    test('does not flag an long-established domain', () async {
      final now = DateTime.utc(2026, 9, 11);
      final viewModel = DueDiligenceViewModel(
        repository: repository(DateTime.utc(2001, 1, 1)),
        now: () => now,
      );

      await viewModel.profile('example.com');

      expect(viewModel.isRecentlyRegistered, isFalse);
    });

    test('reports no age when registration is unknown', () {
      final viewModel = DueDiligenceViewModel(
        repository: repository(DateTime.utc(2026)),
        now: DateTime.now,
      );
      expect(viewModel.registrationAge, isNull);
      expect(viewModel.isRecentlyRegistered, isFalse);
    });
  });
}
