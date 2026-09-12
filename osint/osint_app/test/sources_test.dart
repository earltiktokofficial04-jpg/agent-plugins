import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/core/scan_status.dart';
import 'package:osint_app/ui/features/brand/view_models/brand_view_model.dart';
import 'package:osint_app/ui/features/sources/view_models/sources_view_model.dart';
import 'package:osint_app/ui/features/sources/views/sources_screen.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

/// Serves registry payloads sized to produce recognisable totals.
http.Client _registryClient({bool suffixesFail = false}) =>
    MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('tlds-alpha')) {
        return http.Response(
          '# v\n${List.generate(4, (i) => 'TLD$i').join('\n')}\n',
          200,
        );
      }
      if (url.contains('public_suffix')) {
        if (suffixesFail) return http.Response('', 503);
        return http.Response(
          '// x\n${List.generate(20, (i) => 'suffix$i.test').join('\n')}\n',
          200,
        );
      }
      if (url.contains('rdap')) {
        return http.Response(
          jsonEncode({
            'services': [
              [
                ['a'],
                ['https://one.test/'],
              ],
              [
                ['b'],
                ['https://two.test/'],
              ],
              [
                ['c'],
                ['https://three.test/'],
              ],
            ],
          }),
          200,
        );
      }
      if (url.contains('log_list')) {
        return http.Response(
          jsonEncode({
            'operators': [
              {
                'name': 'Op',
                'logs': [
                  {'url': 'https://l1.test/'},
                  {'url': 'https://l2.test/'},
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('', 404);
    });

SourcesViewModel _viewModel(http.Client client) => SourcesViewModel(
      repository: CatalogRepository(
        registry: IanaRegistryService(client: client),
        now: () => DateTime.utc(2026, 9, 12),
      ),
    );

Widget _harness(SourcesViewModel viewModel) => ChangeNotifierProvider.value(
      value: viewModel,
      child: const MaterialApp(home: SourcesScreen()),
    );

void main() {
  group('SourcesViewModel', () {
    test('starts idle with no catalogue', () {
      final viewModel = _viewModel(_registryClient());
      expect(viewModel.status, ScanStatus.idle);
      expect(viewModel.catalog, isNull);
    });

    test('loads the catalogue and separates the two totals', () async {
      final viewModel = _viewModel(_registryClient());
      await viewModel.load();

      final catalog = viewModel.catalog!;
      // 3 RDAP servers + 2 CT logs + 9 feeds + 9 APIs.
      expect(catalog.queryableCount, 23);
      // 20 public suffixes + 4 TLDs.
      expect(catalog.namespaceCount, 24);
      expect(catalog.totalCount, 47);
      expect(viewModel.status, ScanStatus.done);
    });

    test('reports each fetch stage while loading', () async {
      final viewModel = _viewModel(_registryClient());
      final stages = <String>[];
      viewModel.addListener(() {
        if (viewModel.stage.isNotEmpty) stages.add(viewModel.stage);
      });
      await viewModel.load();
      expect(stages, isNotEmpty);
      expect(viewModel.stage, isEmpty, reason: 'stage clears when done');
    });

    test('ignores a second load while one is running', () async {
      final viewModel = _viewModel(_registryClient());
      final first = viewModel.load();
      await viewModel.load();
      await first;
      expect(viewModel.catalog, isNotNull);
    });

    test('surfaces an unreachable registry as a stale section', () async {
      final viewModel = _viewModel(_registryClient(suffixesFail: true));
      await viewModel.load();
      expect(viewModel.catalog!.hasStaleSections, isTrue);
      expect(viewModel.catalog!.namespaceCount, 4, reason: 'TLDs still count');
    });
  });

  group('SourcesScreen', () {
    testWidgets('renders both totals with their meanings', (tester) async {
      final viewModel = _viewModel(_registryClient());
      await tester.pumpWidget(_harness(viewModel));
      await tester.pumpAndSettle();

      expect(find.text('23'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);
      expect(find.text('queryable sources'), findsOneWidget);
      expect(find.text('sweep namespaces'), findsOneWidget);
    });

    testWidgets('traces every count back to the publishing registry',
        (tester) async {
      final viewModel = _viewModel(_registryClient());
      await tester.pumpWidget(_harness(viewModel));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('source: IANA RDAP bootstrap'),
        findsOneWidget,
      );

      // The namespace sections sit below the fold in a lazy list, so they
      // have to be scrolled into view before they are built.
      await tester.scrollUntilVisible(
        find.textContaining('source: Public Suffix List'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('source: Public Suffix List'),
        findsOneWidget,
      );
    });

    testWidgets('warns when the totals are incomplete', (tester) async {
      final viewModel = _viewModel(_registryClient(suffixesFail: true));
      await tester.pumpWidget(_harness(viewModel));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('could not be reached'),
        findsOneWidget,
      );
    });

    testWidgets('lists every bundled threat feed', (tester) async {
      final viewModel = _viewModel(_registryClient());
      await tester.pumpWidget(_harness(viewModel));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Spamhaus DROP'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Spamhaus DROP'), findsOneWidget);
    });
  });

  group('BrandViewModel namespace mode', () {
    BrandViewModel build(http.Client client) {
      final dns = DnsOverHttpsService(client: client);
      return BrandViewModel(
        repository: BrandRepository(dns: dns),
        namespaceRepository: TldSweepRepository(
          dns: dns,
          registry: IanaRegistryService(client: client),
        ),
      );
    }

    test('defaults to typosquat mode', () {
      expect(build(_registryClient()).mode, SweepMode.typosquat);
    });

    test('switching mode notifies only on a real change', () {
      final viewModel = build(_registryClient());
      var notifications = 0;
      viewModel.addListener(() => notifications++);

      viewModel.setMode(SweepMode.typosquat);
      expect(notifications, 0);

      viewModel.setMode(SweepMode.namespace);
      expect(notifications, 1);
      expect(viewModel.mode, SweepMode.namespace);
    });

    test('reports the namespace count for the selected breadth', () async {
      final viewModel = build(_registryClient());
      viewModel.setBreadth(SweepBreadth.allTlds);
      expect(await viewModel.namespaceCount(), 4);

      viewModel.setBreadth(SweepBreadth.allSuffixes);
      expect(await viewModel.namespaceCount(), 20);
    });

    test('a namespace sweep varies the suffix, not the label', () async {
      final checked = <String>{};
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('tlds-alpha')) {
          return http.Response('# v\nNET\nXYZ\n', 200);
        }
        checked.add(request.url.queryParameters['name'] ?? '');
        return http.Response(jsonEncode({'Status': 3}), 200);
      });

      final viewModel = build(client)
        ..setMode(SweepMode.namespace)
        ..setBreadth(SweepBreadth.allTlds);
      await viewModel.sweep('acme.com');

      expect(checked, containsAll(['acme.net', 'acme.xyz']));
      expect(checked, isNot(contains('exarnple.com')));
      expect(viewModel.status, ScanStatus.done);
    });
  });
}
