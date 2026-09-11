import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the infrastructure recon screen.
class ReconViewModel extends ChangeNotifier {
  ReconViewModel({required ReconRepository repository})
      : _repository = repository;

  final ReconRepository _repository;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  ReconReport? _report;
  ReconReport? get report => _report;

  String _rejection = '';

  /// Why the last request was refused, when [status] is
  /// [ScanStatus.rejected].
  String get rejection => _rejection;

  bool _enrichHosts = false;
  bool get enrichHosts => _enrichHosts;

  bool get isBusy => _status == ScanStatus.running;

  /// Whether to spend Shodan credits enriching resolved addresses.
  void setEnrichHosts(bool value) {
    if (_enrichHosts == value) return;
    _enrichHosts = value;
    notifyListeners();
  }

  /// Scans [input], which must parse to a domain.
  Future<void> scan(String input) async {
    final target = Target.parse(input);
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      _status = ScanStatus.rejected;
      _rejection =
          'Enter a domain such as example.com. Recon needs a domain, not an '
          'IP address or a hash.';
      _report = null;
      notifyListeners();
      return;
    }

    _status = ScanStatus.running;
    _rejection = '';
    notifyListeners();

    final report = await _repository.scan(target, enrichHosts: _enrichHosts);

    _report = report;
    _status = ScanStatus.done;
    notifyListeners();
  }
}
