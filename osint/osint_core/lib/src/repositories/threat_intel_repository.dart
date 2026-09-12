import '../models/ioc_verdict.dart';
import '../models/threat_feed.dart';
import '../models/reports.dart';
import '../models/target.dart';
import '../services/abuseipdb_service.dart';
import '../services/otx_service.dart';
import '../services/virustotal_service.dart';
import 'blocklist_repository.dart';

/// An IOC report paired with per-source status notes.
class ThreatIntelResult {
  const ThreatIntelResult({
    required this.report,
    required this.notes,
    this.blocklist,
  });

  final IocReport report;
  final List<SourceNote> notes;

  /// Bulk feed membership, when the target was an IPv4 address.
  final BlocklistReport? blocklist;
}

/// Enriches an indicator of compromise across reputation sources.
class ThreatIntelRepository {
  ThreatIntelRepository({
    required VirusTotalService virusTotal,
    required AbuseIpdbService abuseIpdb,
    OtxService? otx,
    BlocklistRepository? blocklists,
  })  : _virusTotal = virusTotal,
        _abuseIpdb = abuseIpdb,
        _otx = otx,
        _blocklists = blocklists;

  final VirusTotalService _virusTotal;
  final AbuseIpdbService _abuseIpdb;
  final OtxService? _otx;
  final BlocklistRepository? _blocklists;

  /// Looks [target] up in every source that applies to its kind.
  ///
  /// Sources are queried concurrently and failures are collected as notes
  /// rather than thrown, so a missing AbuseIPDB key never costs the caller its
  /// VirusTotal verdict.
  Future<ThreatIntelResult> enrich(
    Target target, {
    bool checkBlocklists = true,
    void Function(int loaded, int total)? onFeedProgress,
  }) async {
    final otx = _otx;
    final blocklists = _blocklists;

    // Reputation APIs and the bulk feeds are independent, so start the feed
    // download alongside rather than after the API calls.
    // Feeds list IPv4 addresses, so consulting them for a domain or a hash
    // would attach an inapplicable report to the result rather than a useful
    // one. The target type decides, not the caller.
    final blocklistFuture =
        (checkBlocklists && blocklists != null && target.kind == TargetKind.ipv4)
            ? blocklists.check(target, onProgress: onFeedProgress)
            : null;

    final results = await Future.wait([
      _virusTotal.lookup(target),
      _abuseIpdb.check(target),
      if (otx != null) otx.lookup(target),
    ]);

    final verdicts = <IocVerdict>[];
    final notes = <SourceNote>[];

    for (final result in results) {
      notes.add(SourceNote.from(result));
      final verdict = result.valueOrNull;
      if (verdict != null) verdicts.add(verdict);
    }

    BlocklistReport? blocklistReport;
    if (blocklistFuture != null) {
      blocklistReport = await blocklistFuture;
      notes.addAll(blocklistReport.notes);
      final feedVerdict = _feedVerdict(blocklistReport);
      if (feedVerdict != null) verdicts.add(feedVerdict);
    }

    return ThreatIntelResult(
      report: IocReport(indicator: target.value, verdicts: verdicts),
      notes: notes,
      blocklist: blocklistReport,
    );
  }

  /// Condenses feed membership into a single verdict alongside the APIs.
  ///
  /// Returns null when no feed loaded, so that a failed download reads as
  /// "unknown" rather than as a clean bill of health.
  static IocVerdict? _feedVerdict(BlocklistReport report) {
    if (report.feedsChecked == 0) return null;

    final worst = report.worstSeverity;
    final IocSeverity severity;
    if (worst == null) {
      severity = IocSeverity.clean;
    } else {
      severity = switch (worst) {
        FeedSeverity.high => IocSeverity.malicious,
        FeedSeverity.medium => IocSeverity.suspicious,
        // A Tor exit is not an accusation, so a contextual-only hit stays
        // clean and shows up as context in the details instead.
        FeedSeverity.contextual => IocSeverity.clean,
      };
    }

    return IocVerdict(
      source: 'Public blocklists',
      severity: severity,
      detections: report.hits.length,
      totalEngines: report.feedsChecked,
      details: {
        'Feeds searched': '${report.feedsChecked}',
        'Entries searched': '${report.entriesSearched}',
      },
    );
  }
}
