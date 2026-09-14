import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../../data/services/image_indicator_scanner.dart';
import '../../../core/scan_status.dart';

/// Drives reading indicators out of a photo or screenshot.
class ImageScanViewModel extends ChangeNotifier {
  ImageScanViewModel({
    required ImageIndicatorScanner scanner,
    IanaRegistryService? registry,
  })  : _scanner = scanner,
        _registry = registry;

  final ImageIndicatorScanner _scanner;

  /// Supplies the live TLD list, which decides whether `report.pdf` is a
  /// filename or a hostname. Optional: the extractor falls back to a bundled
  /// set so the feature still works with no network.
  final IanaRegistryService? _registry;

  TargetExtractor _extractor = const TargetExtractor();
  bool _tldsLoaded = false;

  /// True once the live IANA list has replaced the bundled fallback.
  bool get usingLiveTlds => _tldsLoaded;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  List<ExtractedTarget> _found = const [];
  List<ExtractedTarget> get found => _found;

  ImageReadout? _readout;

  /// The raw text the image yielded, for when nothing was extracted and the
  /// user needs to see whether OCR read anything at all.
  ImageReadout? get readout => _readout;

  String _message = '';

  /// Why the last attempt produced nothing, when it produced nothing.
  String get message => _message;

  bool get isBusy => _status == ScanStatus.running;

  /// Fetches the live TLD list so filename false positives are suppressed.
  ///
  /// Failure is silent by design: the bundled list keeps the feature usable,
  /// and a toast about a registry download would mean nothing to the user
  /// standing in front of a QR code.
  Future<void> loadTlds() async {
    final registry = _registry;
    if (registry == null || _tldsLoaded) return;
    final result = await registry.tlds();
    final tlds = result.valueOrNull;
    if (tlds == null || tlds.isEmpty) return;
    _extractor = TargetExtractor(knownTlds: tlds.toSet());
    _tldsLoaded = true;
    notifyListeners();
  }

  /// Reads an image from [source] and extracts every indicator in it.
  Future<void> scanImage(ImageSource2 source) async {
    _status = ScanStatus.running;
    _message = '';
    notifyListeners();

    final ImageReadout? readout;
    try {
      readout = await _scanner.readImage(source);
    } catch (error) {
      _status = ScanStatus.rejected;
      _message = 'Could not read the image: $error';
      _found = const [];
      _readout = null;
      notifyListeners();
      return;
    }

    if (readout == null) {
      // Cancelled at the picker — not a failure, and not worth an error.
      _status = _found.isEmpty ? ScanStatus.idle : ScanStatus.done;
      notifyListeners();
      return;
    }

    _readout = readout;
    _found = indicatorsFrom(readout, _extractor);
    _status = ScanStatus.done;

    if (_found.isEmpty) {
      _message = readout.isEmpty
          ? 'Nothing readable in that image — try a sharper or closer shot.'
          : 'Text was read, but no domain, address or hash was found in it.';
    }

    notifyListeners();
  }

  /// Clears the current result.
  void clear() {
    _found = const [];
    _readout = null;
    _message = '';
    _status = ScanStatus.idle;
    notifyListeners();
  }
}
