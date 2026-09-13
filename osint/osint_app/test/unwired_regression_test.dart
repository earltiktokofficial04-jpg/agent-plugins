import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/features/recon/view_models/recon_view_model.dart';
import 'package:osint_app/ui/features/recon/views/recon_screen.dart';
import 'package:osint_app/ui/features/threat_intel/view_models/threat_intel_view_model.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

/// Guards against capabilities that are built, paid for, and then never
/// reach the user — the class of gap an unwired-capability audit turned up.
void main() {
  group('feed download progress reaches the view model', () {
    ThreatIntelViewModel build(List<ThreatFeed> feeds, http.Client client) {
      final keys = InMemoryApiKeyProvider();
      return ThreatIntelViewModel(
        repository: ThreatIntelRepository(
          virusTotal: VirusTotalService(keys: keys, client: client),
          abuseIpdb: AbuseIpdbService(keys: keys, client: client),
          otx: OtxService(client: client),
          blocklists: BlocklistRepository(
            feedService: ThreatFeedService(client: client),
            feeds: feeds,
          ),
        ),
      );
    }

    List<ThreatFeed> feeds(int count) => [
          for (var i = 0; i < count; i++)
            ThreatFeed(
              id: 'f$i',
              name: 'Feed $i',
              url: 'https://feeds.test/$i.txt',
              severity: FeedSeverity.medium,
              description: 'x',
            ),
        ];

    http.Client client() => MockClient((request) async {
          if (request.url.host.contains('feeds.test')) {
            return http.Response('1.2.3.0/24\n', 200);
          }
          return http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200);
        });

    test('progress is null before a lookup starts', () {
      final viewModel = build(feeds(3), client());
      expect(viewModel.feedProgress, isNull);
      expect(viewModel.feedsTotal, 0);
    });

    test('every feed download is reported, ending at 100%', () async {
      // Without this wiring the user sees an indeterminate spinner for up to
      // minutes and cannot tell a live scan from a wedged one.
      final viewModel = build(feeds(4), client());
      final seen = <int>[];
      viewModel.addListener(() {
        if (viewModel.feedsTotal > 0) seen.add(viewModel.feedsLoaded);
      });

      await viewModel.enrich('1.2.3.4');

      expect(seen, isNotEmpty, reason: 'progress must reach the view model');
      expect(seen.last, 4);
      expect(viewModel.feedsTotal, 4);
      expect(viewModel.feedProgress, 1.0);
    });

    test('counters reset between lookups', () async {
      final viewModel = build(feeds(2), client());
      await viewModel.enrich('1.2.3.4');
      expect(viewModel.feedsLoaded, 2);

      await viewModel.enrich('5.6.7.8');
      expect(viewModel.feedsTotal, 2);
      expect(viewModel.feedsLoaded, 2);
    });

    test('a domain lookup reports no feed progress at all', () async {
      // Feeds are IPv4-only, so a domain must not show a feed progress bar.
      final viewModel = build(feeds(3), client());
      await viewModel.enrich('example.com');
      expect(viewModel.feedsTotal, 0);
      expect(viewModel.feedProgress, isNull);
    });
  });

  group('Shodan data the user paid a credit for is rendered', () {
    testWidgets('reverse hostnames, OS and scan date all reach the screen',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.host.contains('crt.sh')) {
          return http.Response('[]', 200);
        }
        if (request.url.host.contains('shodan')) {
          return http.Response(
            jsonEncode({
              'ip_str': '203.0.113.7',
              'ports': [443],
              'hostnames': ['tenant-a.example.net', 'tenant-b.example.net'],
              'org': 'Example Cloud',
              'os': 'Ubuntu',
              'last_update': '2026-08-01T00:00:00.000000',
              'data': [
                {'port': 443, 'transport': 'tcp', 'product': 'nginx'},
              ],
            }),
            200,
          );
        }
        if (request.url.queryParameters['type'] == '1') {
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {
                  'name': 'example.com',
                  'type': 1,
                  'TTL': 60,
                  'data': '203.0.113.7',
                },
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
      });

      final viewModel = ReconViewModel(
        repository: ReconRepository(
          dns: DnsOverHttpsService(client: client),
          crtSh: CrtShService(client: client),
          shodan: ShodanHostService(
            keys: InMemoryApiKeyProvider({ApiKeySource.shodan: 'k'}),
            client: client,
          ),
        ),
      )..setEnrichHosts(true);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: viewModel,
          child: MaterialApp(
            home: Scaffold(body: ReconScreen(onOpenSettings: () {})),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, 'example.com');
      await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('tenant-a.example.net'),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('tenant-a.example.net'), findsOneWidget);
      expect(find.text('tenant-b.example.net'), findsOneWidget);
      expect(find.text('Ubuntu'), findsOneWidget);
      expect(find.text('2026-08-01'), findsOneWidget);
    });
  });
}
