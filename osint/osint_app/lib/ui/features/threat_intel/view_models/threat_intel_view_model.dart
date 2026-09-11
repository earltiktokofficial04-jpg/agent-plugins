import 'package:flutter/foundation.dart';
import 'package:osint_core/osint_core.dart';

import '../../../core/scan_status.dart';

/// Drives the IOC enrichment screen.
class ThreatIntelViewModel extends ChangeNotifier {
  ThreatIntelViewModel({required ThreatIntelRepository repository})
      : _repository = repository;

  final ThreatIntelRepository _repository;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  ThreatIntelResult? _result;
  ThreatIntelResult? get result => _result;

  Target? _target;

  /// The parsed target of the last lookup, so the UI can label the indicator
  /// with the kind that was actually detected.
  Target? get target => _target;

  String _rejection = '';
  String get rejection => _rejection;

  bool get isBusy => _status == ScanStatus.running;

  /// Enriches [input], which may be a domain, IP, URL or file hash.
  Future<void> enrich(String input) async {
    final target = Target.parse(input);
    if (target.kind == TargetKind.unknown) {
      _status = ScanStatus.rejected;
      _rejection =
          'Enter a domain, IP address, URL, or an MD5, SHA-1 or SHA-256 hash.';
      _result = null;
      notifyListeners();
      return;
    }

    _target = target;
    _status = ScanStatus.running;
    _rejection = '';
    notifyListeners();

    final result = await _repository.enrich(target);

    _result = result;
    _status = ScanStatus.done;
    notifyListeners();
  }
}
