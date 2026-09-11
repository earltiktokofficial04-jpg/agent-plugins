import '../models/ioc_verdict.dart';
import '../models/reports.dart';
import '../models/target.dart';
import '../services/abuseipdb_service.dart';
import '../services/virustotal_service.dart';

/// An IOC report paired with per-source status notes.
class ThreatIntelResult {
  const ThreatIntelResult({required this.report, required this.notes});

  final IocReport report;
  final List<SourceNote> notes;
}

/// Enriches an indicator of compromise across reputation sources.
class ThreatIntelRepository {
  ThreatIntelRepository({
    required VirusTotalService virusTotal,
    required AbuseIpdbService abuseIpdb,
  })  : _virusTotal = virusTotal,
        _abuseIpdb = abuseIpdb;

  final VirusTotalService _virusTotal;
  final AbuseIpdbService _abuseIpdb;

  /// Looks [target] up in every source that applies to its kind.
  ///
  /// Sources are queried concurrently and failures are collected as notes
  /// rather than thrown, so a missing AbuseIPDB key never costs the caller its
  /// VirusTotal verdict.
  Future<ThreatIntelResult> enrich(Target target) async {
    final results = await Future.wait([
      _virusTotal.lookup(target),
      _abuseIpdb.check(target),
    ]);

    final verdicts = <IocVerdict>[];
    final notes = <SourceNote>[];

    for (final result in results) {
      notes.add(SourceNote.from(result));
      final verdict = result.valueOrNull;
      if (verdict != null) verdicts.add(verdict);
    }

    return ThreatIntelResult(
      report: IocReport(indicator: target.value, verdicts: verdicts),
      notes: notes,
    );
  }
}
