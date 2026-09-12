import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Which family of look-alikes to sweep for.
enum SweepMode {
  /// Mutate the label, hold the suffix fixed: exarnple.com.
  typosquat,

  /// Hold the label, vary the suffix: example.tk, example.com.my.
  namespace,
}

/// Drives the brand-protection sweep screen.
///
/// The sweep is the only feature that makes hundreds of requests, so this
/// view model exposes both a candidate preview (free, local) and live progress
/// during the checked phase.
class BrandViewModel extends ChangeNotifier {
  BrandViewModel({
    required BrandRepository repository,
    required TldSweepRepository namespaceRepository,
  })  : _repository = repository,
        _namespaceRepository = namespaceRepository;

  final BrandRepository _repository;
  final TldSweepRepository _namespaceRepository;

  SweepMode _mode = SweepMode.typosquat;
  SweepMode get mode => _mode;

  SweepBreadth _breadth = SweepBreadth.allTlds;
  SweepBreadth get breadth => _breadth;

  /// Switches between mutating the label and varying the suffix.
  void setMode(SweepMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
  }

  /// How far a namespace sweep should reach.
  void setBreadth(SweepBreadth value) {
    if (_breadth == value) return;
    _breadth = value;
    notifyListeners();
  }

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

  /// Sweeps look-alikes of [input] using the selected mode.
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

    void progress(int checked, int total) {
      _checked = checked;
      _total = total;
      notifyListeners();
    }

    final report = switch (_mode) {
      SweepMode.typosquat => await _repository.sweep(
          target.value,
          limit: _limit,
          onProgress: progress,
        ),
      SweepMode.namespace => await _namespaceRepository.sweep(
          target.value,
          breadth: _breadth,
          limit: _limit,
          onProgress: progress,
        ),
    };

    _report = report;
    _status = ScanStatus.done;
    notifyListeners();
  }

  /// How many namespaces the selected breadth covers, for the UI to show
  /// before any request is made.
  Future<int> namespaceCount() async =>
      (await _namespaceRepository.namespacesFor(_breadth)).length;
}
