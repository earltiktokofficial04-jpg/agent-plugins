import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/ui/features/recon/view_models/recon_view_model.dart';
import 'package:osint_app/ui/features/recon/views/recon_screen.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

/// Serves a certificate covering [hostCount] subdomains.
http.Client _clientWithHosts(int hostCount) => MockClient((request) async {
  if (request.url.host.contains('crt.sh')) {
    final names = [
      'example.com',
      for (var i = 0; i < hostCount; i++) 'host$i.example.com',
    ].join('\n');
    return http.Response(
      jsonEncode([
        {
          'issuer_name': 'CN=CA',
          'common_name': 'example.com',
          'name_value': names,
          'not_before': '2026-01-01T00:00:00',
          'not_after': '2026-04-01T00:00:00',
        },
      ]),
      200,
    );
  }
  return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
});

Widget _harness(ReconViewModel viewModel) => ChangeNotifierProvider.value(
  value: viewModel,
  child: MaterialApp(
    home: Scaffold(body: ReconScreen(onOpenSettings: () {})),
  ),
);

ReconViewModel _viewModel(http.Client client) => ReconViewModel(
  repository: ReconRepository(
    dns: DnsOverHttpsService(client: client),
    crtSh: CrtShService(client: client),
  ),
);

Future<void> _scan(WidgetTester tester, String target) async {
  await tester.enterText(find.byType(TextField).first, target);
  await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a large host list is capped and says how many it hid', (
    tester,
  ) async {
    // Building thousands of rows into a Column janks the frame and can get
    // the app killed. Capping silently is just as bad: a header reading
    // "2,000" above fifty rows says the list is complete when it is not.
    final viewModel = _viewModel(_clientWithHosts(2000));
    await tester.pumpWidget(_harness(viewModel));
    await _scan(tester, 'example.com');

    await tester.scrollUntilVisible(
      find.textContaining('more hosts not shown'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('more hosts not shown'), findsOneWidget);
    expect(find.text('host0.example.com'), findsOneWidget);
    expect(find.text('host1999.example.com'), findsNothing);
  });

  testWidgets('a short list is rendered whole with no truncation note', (
    tester,
  ) async {
    final viewModel = _viewModel(_clientWithHosts(3));
    await tester.pumpWidget(_harness(viewModel));
    await _scan(tester, 'example.com');

    expect(find.textContaining('not shown'), findsNothing);
    expect(find.text('host2.example.com'), findsOneWidget);
  });

  testWidgets('the previous target\'s results are hidden while a scan runs', (
    tester,
  ) async {
    // Leaving them up means the header names one domain while the rows
    // describe another, with nothing on screen saying which.
    final gate = <Completer<http.Response>>[];
    final viewModel = _viewModel(
      MockClient((request) async {
        if (request.url.host.contains('crt.sh')) {
          final completer = Completer<http.Response>();
          gate.add(completer);
          return completer.future;
        }
        return http.Response(jsonEncode({'Status': 0, 'Answer': []}), 200);
      }),
    );

    await tester.pumpWidget(_harness(viewModel));

    await tester.enterText(find.byType(TextField).first, 'first.example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
    await tester.pump();
    gate.first.complete(http.Response('[]', 200));
    await tester.pumpAndSettle();
    expect(find.text('first.example.com'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'second.example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(
      find.text('first.example.com'),
      findsNothing,
      reason: 'stale results must not sit under a new target',
    );

    gate.last.complete(http.Response('[]', 200));
    await tester.pumpAndSettle();
  });

  testWidgets('an unrelated notification does not revert what was typed', (
    tester,
  ) async {
    // The field mirrors a target handed over from the image scanner. Reacting
    // to every notification instead of an actual change meant toggling a
    // switch threw away whatever the user had typed since the last scan.
    final viewModel = _viewModel(_clientWithHosts(1));
    await tester.pumpWidget(_harness(viewModel));
    await _scan(tester, 'first.example.com');

    await tester.enterText(find.byType(TextField).first, 'typed-but-not-run');
    await tester.pump();

    // Any notification that is not a new target.
    viewModel.setEnrichHosts(true);
    await tester.pumpAndSettle();

    expect(
      find.text('typed-but-not-run'),
      findsOneWidget,
      reason: 'the field must keep what the user typed',
    );
  });

  testWidgets('a repository failure surfaces instead of hanging the screen', (
    tester,
  ) async {
    final viewModel = ReconViewModel(
      repository: ReconRepository(
        dns: DnsOverHttpsService(
          client: MockClient((_) async => throw StateError('boom')),
        ),
        crtSh: CrtShService(
          client: MockClient((_) async => throw StateError('boom')),
        ),
      ),
    );

    await tester.pumpWidget(_harness(viewModel));
    await _scan(tester, 'example.com');

    expect(viewModel.isBusy, isFalse, reason: 'the Scan button must re-enable');
  });
}
