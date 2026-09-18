import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/data/services/image_indicator_scanner.dart';
import 'package:osint_app/ui/core/scan_status.dart';
import 'package:osint_app/ui/features/image_scan/view_models/image_scan_view_model.dart';
import 'package:osint_app/ui/features/recon/view_models/recon_view_model.dart';
import 'package:osint_core/osint_core.dart';

/// A scanner whose readouts are released one at a time, so a second request
/// can be started while the first is still in flight.
class _GatedScanner implements ImageIndicatorScanner {
  final List<Completer<ImageReadout?>> pending = [];

  @override
  Future<ImageReadout?> readImage(ImageSource2 source) {
    final completer = Completer<ImageReadout?>();
    pending.add(completer);
    return completer.future;
  }
}

/// A resolver whose responses are released one at a time.
class _GatedClient {
  final List<Completer<http.Response>> pending = [];

  http.Client get client => MockClient((_) {
    final completer = Completer<http.Response>();
    pending.add(completer);
    return completer.future;
  });
}

void main() {
  group('a superseded request never overwrites a newer one', () {
    testWidgets('image scan: the first readout is discarded', (tester) async {
      // The image scanner hands a target to a view model that may already be
      // busy, so two runs overlap. Without a generation check the slower one
      // wins and the screen shows results for a target the user moved on
      // from — the worst kind of wrong, because it looks right.
      final scanner = _GatedScanner();
      final viewModel = ImageScanViewModel(scanner: scanner);

      unawaited(viewModel.scanImage(ImageSource2.gallery));
      await tester.pump();
      unawaited(viewModel.scanImage(ImageSource2.camera));
      await tester.pump();

      expect(scanner.pending, hasLength(2));

      // Second request answers first, then the stale first one answers.
      scanner.pending[1].complete(
        const ImageReadout(
          recognisedText: 'second.example.com',
          codePayloads: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(viewModel.found.single.target.value, 'second.example.com');

      scanner.pending[0].complete(
        const ImageReadout(
          recognisedText: 'first.example.com',
          codePayloads: [],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        viewModel.found.single.target.value,
        'second.example.com',
        reason: 'the stale first response must not overwrite the second',
      );
    });

    testWidgets('recon: a stale scan does not clobber the newer report', (
      tester,
    ) async {
      final gate = _GatedClient();
      final client = gate.client;
      final viewModel = ReconViewModel(
        repository: ReconRepository(
          dns: DnsOverHttpsService(client: client),
          crtSh: CrtShService(client: client),
        ),
      );

      unawaited(viewModel.scan('first.example.com'));
      await tester.pump();
      unawaited(viewModel.scan('second.example.com'));
      await tester.pump();

      expect(viewModel.lastInput, 'second.example.com');

      // Release everything; both runs complete, newest must win.
      for (final completer in gate.pending) {
        if (!completer.isCompleted) {
          completer.complete(http.Response(jsonEncode({'Status': 3}), 200));
        }
      }
      await tester.pumpAndSettle();

      expect(viewModel.status, ScanStatus.done);
      expect(viewModel.report!.target.value, 'second.example.com');
    });
  });

  group('a disposed view model does not notify', () {
    testWidgets('no exception when a response lands after dispose', (
      tester,
    ) async {
      // Flutter throws if notifyListeners runs on a disposed ChangeNotifier,
      // which is exactly what a slow scan does when the user leaves.
      final scanner = _GatedScanner();
      final viewModel = ImageScanViewModel(scanner: scanner);

      unawaited(viewModel.scanImage(ImageSource2.gallery));
      await tester.pump();

      viewModel.dispose();

      scanner.pending.first.complete(
        const ImageReadout(
          recognisedText: 'late.example.com',
          codePayloads: [],
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
