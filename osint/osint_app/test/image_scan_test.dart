import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_app/data/services/image_indicator_scanner.dart';
import 'package:osint_app/ui/core/scan_status.dart';
import 'package:osint_app/ui/features/image_scan/view_models/image_scan_view_model.dart';
import 'package:osint_app/ui/features/image_scan/views/image_scan_screen.dart';
import 'package:osint_core/osint_core.dart';
import 'package:provider/provider.dart';

/// Stands in for the camera and ML Kit, neither of which exists in a test.
class _FakeScanner implements ImageIndicatorScanner {
  _FakeScanner({this.readout, this.throws = false});

  ImageReadout? readout;
  bool throws;
  final List<ImageSource2> calls = [];

  @override
  Future<ImageReadout?> readImage(ImageSource2 source) async {
    calls.add(source);
    if (throws) throw StateError('camera unavailable');
    return readout;
  }
}

ImageReadout _readout({String text = '', List<String> codes = const []}) =>
    ImageReadout(recognisedText: text, codePayloads: codes);

void main() {
  group('ImageScanViewModel', () {
    test('starts idle with nothing found', () {
      final viewModel = ImageScanViewModel(scanner: _FakeScanner());
      expect(viewModel.status, ScanStatus.idle);
      expect(viewModel.found, isEmpty);
      expect(viewModel.usingLiveTlds, isFalse);
    });

    test('extracts indicators from OCR text', () async {
      final scanner = _FakeScanner(
        readout: _readout(
          text: 'Report: C2 at 185.220.101.5 and hxxps://login-bank[.]tk',
        ),
      );
      final viewModel = ImageScanViewModel(scanner: scanner);

      await viewModel.scanImage(ImageSource2.gallery);

      expect(viewModel.status, ScanStatus.done);
      expect(
        viewModel.found.map((e) => e.target.value),
        containsAll(['185.220.101.5', 'login-bank.tk']),
      );
      expect(scanner.calls, [ImageSource2.gallery]);
    });

    test('attributes a value to the QR code when both sources have it',
        () async {
      // A QR payload is machine-readable and exact; OCR of the same string
      // may be misread, so the code is the better provenance.
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(
            text: 'pay-now.example.com printed underneath',
            codes: ['https://pay-now.example.com/qr'],
          ),
        ),
      );

      await viewModel.scanImage(ImageSource2.camera);

      expect(viewModel.found, hasLength(1));
      expect(viewModel.found.single.origin, TargetOrigin.code);
    });

    test('a cancelled picker is not an error', () async {
      final viewModel =
          ImageScanViewModel(scanner: _FakeScanner(readout: null));

      await viewModel.scanImage(ImageSource2.camera);

      expect(viewModel.status, ScanStatus.idle);
      expect(viewModel.message, isEmpty);
      expect(viewModel.found, isEmpty);
    });

    test('a thrown platform error is reported, not swallowed', () async {
      final viewModel =
          ImageScanViewModel(scanner: _FakeScanner(throws: true));

      await viewModel.scanImage(ImageSource2.camera);

      expect(viewModel.status, ScanStatus.rejected);
      expect(viewModel.message, contains('Could not read the image'));
    });

    test('distinguishes an unreadable image from one with no indicators',
        () async {
      final blank = ImageScanViewModel(scanner: _FakeScanner(readout: _readout()));
      await blank.scanImage(ImageSource2.camera);
      expect(blank.message, contains('Nothing readable'));

      final prose = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(text: 'Meeting notes from Tuesday, no links here'),
        ),
      );
      await prose.scanImage(ImageSource2.camera);
      expect(prose.message, contains('no domain, address or hash'));
      // The text is retained so the user can see what OCR actually read.
      expect(prose.readout!.recognisedText, contains('Meeting notes'));
    });

    test('the live TLD list suppresses filename false positives', () async {
      // With the bundled list, an unusual TLD is missed; with the live IANA
      // list it resolves. Both must still reject real filenames.
      final client = MockClient(
        (_) async => http.Response('# v\nCOM\nZUERICH\n', 200),
      );
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(text: 'see brand.zuerich and report.pdf'),
        ),
        registry: IanaRegistryService(client: client),
      );

      await viewModel.scanImage(ImageSource2.gallery);
      expect(viewModel.found, isEmpty, reason: 'bundled list lacks .zuerich');

      await viewModel.loadTlds();
      expect(viewModel.usingLiveTlds, isTrue);

      await viewModel.scanImage(ImageSource2.gallery);
      expect(
        viewModel.found.map((e) => e.target.value),
        ['brand.zuerich'],
        reason: 'report.pdf must still be rejected',
      );
    });

    test('a failed TLD fetch leaves the bundled list in place', () async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(readout: _readout(text: 'example.com')),
        registry: IanaRegistryService(
          client: MockClient((_) async => http.Response('', 503)),
        ),
      );

      await viewModel.loadTlds();
      expect(viewModel.usingLiveTlds, isFalse);

      await viewModel.scanImage(ImageSource2.gallery);
      expect(viewModel.found.single.target.value, 'example.com');
    });

    test('clear resets the result', () async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(readout: _readout(text: 'example.com')),
      );
      await viewModel.scanImage(ImageSource2.gallery);
      expect(viewModel.found, isNotEmpty);

      viewModel.clear();
      expect(viewModel.found, isEmpty);
      expect(viewModel.status, ScanStatus.idle);
      expect(viewModel.readout, isNull);
    });
  });

  group('ImageScanScreen', () {
    Widget harness(
      ImageScanViewModel viewModel,
      void Function(ExtractedTarget, ImageScanAction) onChosen,
    ) =>
        ChangeNotifierProvider.value(
          value: viewModel,
          child: MaterialApp(
            home: ImageScanScreen(onTargetChosen: onChosen),
          ),
        );

    testWidgets('offers both camera and gallery', (tester) async {
      await tester.pumpWidget(
        harness(ImageScanViewModel(scanner: _FakeScanner()), (_, __) {}),
      );
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.textContaining('never uploaded'), findsOneWidget);
    });

    testWidgets('renders a found indicator with its origin and raw text',
        (tester) async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(text: 'Go To EVIL-CORP.COM now'),
        ),
      );
      await tester.pumpWidget(harness(viewModel, (_, __) {}));
      await viewModel.scanImage(ImageSource2.gallery);
      await tester.pumpAndSettle();

      expect(find.text('evil-corp.com'), findsOneWidget);
      expect(find.text('read as: EVIL-CORP.COM'), findsOneWidget);
      expect(find.text('domain'), findsOneWidget);
    });

    testWidgets('offers Recon for a domain but not for a hash',
        (tester) async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(
            text: 'evil.com d41d8cd98f00b204e9800998ecf8427e',
          ),
        ),
      );
      await tester.pumpWidget(harness(viewModel, (_, __) {}));
      await viewModel.scanImage(ImageSource2.gallery);
      await tester.pumpAndSettle();

      // Two indicators, both get Reputation; only the domain gets Recon,
      // because recon has nothing to say about a file hash.
      expect(find.text('Reputation'), findsNWidgets(2));
      expect(find.text('Recon'), findsOneWidget);
    });

    testWidgets('hands the chosen indicator and action back', (tester) async {
      ExtractedTarget? chosen;
      ImageScanAction? action;

      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(readout: _readout(text: 'evil.com')),
      );
      await tester.pumpWidget(
        harness(viewModel, (extracted, selected) {
          chosen = extracted;
          action = selected;
        }),
      );
      await viewModel.scanImage(ImageSource2.gallery);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reputation'));
      await tester.pumpAndSettle();

      expect(chosen!.target.value, 'evil.com');
      expect(action, ImageScanAction.threatIntel);
    });

    testWidgets('warns when indicators arrived defanged', (tester) async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(text: 'IOC: login-bank[.]tk'),
        ),
      );
      await tester.pumpWidget(harness(viewModel, (_, __) {}));
      await viewModel.scanImage(ImageSource2.gallery);
      await tester.pumpAndSettle();

      expect(find.textContaining('written defanged'), findsOneWidget);
    });

    testWidgets('shows the OCR text when nothing could be extracted',
        (tester) async {
      final viewModel = ImageScanViewModel(
        scanner: _FakeScanner(
          readout: _readout(text: 'Just some prose with no indicators'),
        ),
      );
      await tester.pumpWidget(harness(viewModel, (_, __) {}));
      await viewModel.scanImage(ImageSource2.gallery);
      await tester.pumpAndSettle();

      expect(find.text('Text that was read'), findsOneWidget);
      expect(
        find.text('Just some prose with no indicators'),
        findsOneWidget,
      );
    });
  });
}
