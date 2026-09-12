import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/features/threat_intel/view_models/threat_intel_view_model.dart';
import 'package:osint_app/ui/features/threat_intel/views/threat_intel_screen.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

const _feed = ThreatFeed(
  id: 'serious',
  name: 'Serious feed',
  url: 'https://feeds.test/list.txt',
  severity: FeedSeverity.high,
  description: 'Criminal-controlled netblocks.',
);

Widget _harness(http.Client client, {List<ThreatFeed> feeds = const [_feed]}) {
  final keys = InMemoryApiKeyProvider();
  final viewModel = ThreatIntelViewModel(
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

  return ChangeNotifierProvider.value(
    value: viewModel,
    child: MaterialApp(
      home: Scaffold(
        body: ThreatIntelScreen(onOpenSettings: () {}),
      ),
    ),
  );
}

Future<void> _lookup(WidgetTester tester, String indicator) async {
  await tester.enterText(find.byType(TextField).first, indicator);
  await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a feed hit with the block that matched',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.host.contains('feeds.test')) {
        return http.Response('1.2.3.0/24\n', 200);
      }
      return http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200);
    });

    await tester.pumpWidget(_harness(client));
    await _lookup(tester, '1.2.3.4');

    expect(find.text('Public blocklists'), findsWidgets);
    expect(find.text('Serious feed'), findsOneWidget);
    expect(find.text('listed as 1.2.3.0/24'), findsOneWidget);
    expect(find.text('Malicious'), findsWidgets);
  });

  testWidgets('says plainly that a failed feed load is not an all-clear',
      (tester) async {
    // The most dangerous thing this screen could do is let a failed download
    // read as a clean result.
    final client = MockClient((request) async {
      if (request.url.host.contains('feeds.test')) {
        return http.Response('', 503);
      }
      return http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200);
    });

    await tester.pumpWidget(_harness(client));
    await _lookup(tester, '1.2.3.4');

    expect(find.textContaining('not an all-clear'), findsOneWidget);
  });

  testWidgets('reports a clean address as not listed', (tester) async {
    final client = MockClient((request) async {
      if (request.url.host.contains('feeds.test')) {
        return http.Response('9.9.9.0/24\n', 200);
      }
      return http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200);
    });

    await tester.pumpWidget(_harness(client));
    await _lookup(tester, '1.2.3.4');

    expect(find.textContaining('Not listed by any feed'), findsOneWidget);
  });

  testWidgets('shows no blocklist card for a domain target', (tester) async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'pulse_info': {'count': 0}}), 200),
    );

    await tester.pumpWidget(_harness(client, feeds: const []));
    await _lookup(tester, 'example.com');

    expect(find.text('Public blocklists'), findsNothing);
  });
}
