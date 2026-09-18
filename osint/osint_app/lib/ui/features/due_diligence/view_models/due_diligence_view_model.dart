import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the corporate due-diligence screen.
class DueDiligenceViewModel extends ChangeNotifier {
  DueDiligenceViewModel({
    required DueDiligenceRepository repository,
    DateTime Function() now = DateTime.now,
  }) : _repository = repository,
       _now = now;

  final DueDiligenceRepository _repository;

  /// Injected so that age calculations stay testable.
  final DateTime Function() _now;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  DueDiligenceReport? _report;
  DueDiligenceReport? get report => _report;

  String _rejection = '';
  String get rejection => _rejection;

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

  /// Age of the registration, or null when it is unknown.
  Duration? get registrationAge => _report?.registration?.ageAt(_now());

  /// True when the domain was registered within the last 90 days.
  ///
  /// Surfaced prominently because a very young domain is the single strongest
  /// signal in both phishing triage and counterparty checks.
  bool get isRecentlyRegistered {
    final age = registrationAge;
    return age != null && age.inDays < 90;
  }

  /// Profiles [input], which must be a domain.
  Future<void> profile(String input) async {
    final target = Target.parse(input);
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      _status = ScanStatus.rejected;
      _rejection = 'Enter the organisation\'s domain, such as example.com.';
      _report = null;
      _notify();
      return;
    }

    final generation = _beginRequest();
    _status = ScanStatus.running;
    _rejection = '';
    _notify();

    final report = await _repository.profile(target);
    if (!_isCurrent(generation)) return;

    _report = report;
    _status = ScanStatus.done;
    _notify();
  }
}
