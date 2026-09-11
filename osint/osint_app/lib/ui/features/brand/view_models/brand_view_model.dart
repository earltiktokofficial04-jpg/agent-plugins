import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the brand-protection sweep screen.
///
/// The sweep is the only feature that makes hundreds of requests, so this
/// view model exposes both a candidate preview (free, local) and live progress
/// during the checked phase.
class BrandViewModel extends ChangeNotifier {
  BrandViewModel({required BrandRepository repository})
      : _repository = repository;

  final BrandRepository _repository;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  BrandReport? _report;
  BrandReport? get report => _report;

  String _rejection = '';
  String get rejection => _rejection;

  int _checked = 0;

  /// Candidates checked so far in the running sweep.
  int get checked => _checked;

  int _total = 0;

  /// Candidates the running sweep will check in total.
  int get total => _total;

  int _limit = 150;

  /// How many candidates a sweep is allowed to check.
  int get limit => _limit;

  bool get isBusy => _status == ScanStatus.running;

  /// Fraction complete, or null before a sweep starts.
  double? get progress =>
      _total == 0 ? null : (_checked / _total).clamp(0.0, 1.0);

  void setLimit(int value) {
    if (_limit == value) return;
    _limit = value;
    notifyListeners();
  }

  /// Counts the candidates for [input] without making any request.
  ///
  /// Lets the screen tell the user how large the sweep would be before they
  /// spend mobile data on it.
  int previewCount(String input) {
    final target = Target.parse(input);
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      return 0;
    }
    return _repository.candidatesFor(target.value).length;
  }

  /// Sweeps look-alikes of [input].
  Future<void> sweep(String input) async {
    final target = Target.parse(input);
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      _status = ScanStatus.rejected;
      _rejection = 'Enter the brand domain to protect, such as example.com.';
      _report = null;
      notifyListeners();
      return;
    }

    _status = ScanStatus.running;
    _rejection = '';
    _checked = 0;
    _total = 0;
    notifyListeners();

    final report = await _repository.sweep(
      target.value,
      limit: _limit,
      onProgress: (checked, total) {
        _checked = checked;
        _total = total;
        notifyListeners();
      },
    );

    _report = report;
    _status = ScanStatus.done;
    notifyListeners();
  }
}
