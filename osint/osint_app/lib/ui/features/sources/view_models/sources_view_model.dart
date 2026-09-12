import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the source catalogue screen.
///
/// The catalogue is fetched rather than hard-coded so the numbers shown are
/// the ones the governing registries publish today, not figures baked in when
/// the app was built.
class SourcesViewModel extends ChangeNotifier {
  SourcesViewModel({required CatalogRepository repository})
      : _repository = repository;

  final CatalogRepository _repository;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  SourceCatalog? _catalog;
  SourceCatalog? get catalog => _catalog;

  String _stage = '';

  /// Which registry is currently being fetched.
  String get stage => _stage;

  bool get isBusy => _status == ScanStatus.running;

  /// Fetches every registry and rebuilds the catalogue.
  Future<void> load() async {
    if (_status == ScanStatus.running) return;

    _status = ScanStatus.running;
    _stage = 'Starting';
    notifyListeners();

    final catalog = await _repository.load(
      onProgress: (stage) {
        _stage = stage;
        notifyListeners();
      },
    );

    _catalog = catalog;
    _stage = '';
    _status = ScanStatus.done;
    notifyListeners();
  }
}
