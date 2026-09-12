import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/features/brand/view_models/brand_view_model.dart';
import 'package:osint_app/ui/features/due_diligence/view_models/due_diligence_view_model.dart';
import 'package:osint_app/ui/features/home/views/home_shell.dart';
import 'package:osint_app/ui/features/recon/view_models/recon_view_model.dart';
import 'package:osint_app/ui/features/threat_intel/view_models/threat_intel_view_model.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

/// A client that answers every source with canned data for example.com.
http.Client _client() => MockClient((request) async {
      if (request.url.host.contains('crt.sh')) {
        return http.Response(
          jsonEncode([
            {
              'issuer_name': "CN=R3, O=Let's Encrypt",
              'common_name': 'example.com',
              'name_value': 'example.com\nvpn.example.com',
              'not_before': '2026-01-01T00:00:00',
              'not_after': '2026-04-01T00:00:00',
            },
          ]),
          200,
        );
      }
      if (request.url.host.contains('rdap')) {
        return http.Response(jsonEncode({'ldhName': 'example.com'}), 200);
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
                'data': '93.184.216.34',
              },
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
    });

Widget _harness() {
  final client = _client();
  final dns = DnsOverHttpsService(client: client);
  final crtSh = CrtShService(client: client);
  final keys = InMemoryApiKeyProvider();

  return MultiProvider(
    providers: [
      ChangeNotifierProvider(
        create: (_) => ReconViewModel(
          repository: ReconRepository(dns: dns, crtSh: crtSh),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => ThreatIntelViewModel(
          repository: ThreatIntelRepository(
            virusTotal: VirusTotalService(keys: keys, client: client),
            abuseIpdb: AbuseIpdbService(keys: keys, client: client),
          ),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => BrandViewModel(
          repository: BrandRepository(dns: dns),
          namespaceRepository: TldSweepRepository(
            dns: dns,
            registry: IanaRegistryService(client: client),
          ),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => DueDiligenceViewModel(
          repository: DueDiligenceRepository(
            rdap: RdapService(client: client),
            dns: dns,
            crtSh: crtSh,
          ),
        ),
      ),
    ],
    child: const MaterialApp(home: HomeShell()),
  );
}

void main() {
  testWidgets('renders four feature tabs', (tester) async {
    await tester.pumpWidget(_harness());

    expect(find.text('Recon'), findsWidgets);
    expect(find.text('Intel'), findsOneWidget);
    expect(find.text('Brand'), findsOneWidget);
    expect(find.text('Diligence'), findsOneWidget);
  });

  testWidgets('switching tabs changes the title', (tester) async {
    await tester.pumpWidget(_harness());

    await tester.tap(find.text('Diligence'));
    await tester.pumpAndSettle();

    expect(find.text('Due diligence'), findsOneWidget);
  });

  testWidgets('a recon scan renders DNS records and CT hosts', (tester) async {
    await tester.pumpWidget(_harness());

    await tester.enterText(find.byType(TextField).first, 'example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
    await tester.pumpAndSettle();

    expect(find.text('93.184.216.34'), findsWidgets);
    expect(find.text('vpn.example.com'), findsOneWidget);
    expect(find.text('DNS records'), findsOneWidget);
    expect(find.text('Discovered hosts'), findsOneWidget);
  });

  testWidgets('an invalid recon target shows guidance, not a crash',
      (tester) async {
    await tester.pumpWidget(_harness());

    await tester.enterText(find.byType(TextField).first, '8.8.8.8');
    await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Recon needs a domain'),
      findsOneWidget,
    );
  });

  testWidgets('the scope dialog states that lookups are passive',
      (tester) async {
    await tester.pumpWidget(_harness());

    await tester.tap(find.byTooltip('About'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Every lookup is passive'), findsOneWidget);
    expect(
      find.textContaining('no port scanning'),
      findsOneWidget,
    );
  });
}
