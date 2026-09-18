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

  String _lastInput = '';

  /// What was last submitted, so a screen can show a target handed to it from
  /// elsewhere — the image scanner, for one — in its input field.
  String get lastInput => _lastInput;

  bool get isBusy => _status == ScanStatus.running;

  int _generation = 0;
  bool _disposed = false;

  /// Starts a new request and returns its generation token.
  ///
  /// A second request can arrive while the first is still in flight — the
  /// image scanner hands a target straight to a view model that may already
  /// be busy — and without this the slower response overwrites the newer one,
  /// so the screen shows results for a target the user has moved on from.
  int _beginRequest() => ++_generation;

  /// True when [generation] is still the request the user is waiting for.
  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  /// Notifies only while this view model is still mounted.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Whether to spend Shodan credits enriching resolved addresses.
  void setEnrichHosts(bool value) {
    if (_enrichHosts == value) return;
    _enrichHosts = value;
    _notify();
  }

  /// Scans [input], which must parse to a domain.
  Future<void> scan(String input) async {
    _lastInput = input.trim();
    final target = Target.parse(input);
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      _status = ScanStatus.rejected;
      _rejection =
          'Enter a domain such as example.com. Recon needs a domain, not an '
          'IP address or a hash.';
      _report = null;
      _notify();
      return;
    }

    final generation = _beginRequest();
    _status = ScanStatus.running;
    _rejection = '';
    _notify();

    final report = await _repository.scan(target, enrichHosts: _enrichHosts);
    if (!_isCurrent(generation)) return;

    _report = report;
    _status = ScanStatus.done;
    _notify();
  }
}
