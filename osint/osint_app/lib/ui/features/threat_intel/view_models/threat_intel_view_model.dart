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

  int _feedsLoaded = 0;

  /// Bulk feeds downloaded so far in the running lookup.
  int get feedsLoaded => _feedsLoaded;

  int _feedsTotal = 0;

  /// Bulk feeds the running lookup will download.
  int get feedsTotal => _feedsTotal;

  /// Fraction of the feed download complete, or null when none is running.
  ///
  /// An IPv4 lookup pulls several multi-megabyte volunteer-hosted lists, which
  /// can take minutes on mobile. Without this the user cannot tell a scan
  /// that is nearly done from one that has wedged, and will kill the app.
  double? get feedProgress =>
      _feedsTotal == 0 ? null : (_feedsLoaded / _feedsTotal).clamp(0.0, 1.0);

  String _lastInput = '';

  /// What was last submitted, so a screen can show a target handed to it from
  /// elsewhere — the image scanner, for one — in its input field.
  String get lastInput => _lastInput;

  bool get isBusy => _status == ScanStatus.running;

  /// Enriches [input], which may be a domain, IP, URL or file hash.
  Future<void> enrich(String input) async {
    _lastInput = input.trim();
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
    _feedsLoaded = 0;
    _feedsTotal = 0;
    notifyListeners();

    final result = await _repository.enrich(
      target,
      onFeedProgress: (loaded, total) {
        _feedsLoaded = loaded;
        _feedsTotal = total;
        notifyListeners();
      },
    );

    _result = result;
    _status = ScanStatus.done;
    notifyListeners();
  }
}
