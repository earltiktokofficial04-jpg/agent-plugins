import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the corporate due-diligence screen.
class DueDiligenceViewModel extends ChangeNotifier {
  DueDiligenceViewModel({
    required DueDiligenceRepository repository,
    DateTime Function() now = DateTime.now,
  })  : _repository = repository,
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
      notifyListeners();
      return;
    }

    _status = ScanStatus.running;
    _rejection = '';
    notifyListeners();

    final report = await _repository.profile(target);

    _report = report;
    _status = ScanStatus.done;
    notifyListeners();
  }
}
