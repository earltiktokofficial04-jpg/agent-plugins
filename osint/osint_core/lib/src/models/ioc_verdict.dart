/// How strongly a reputation source condemns an indicator.
enum IocSeverity { unknown, clean, suspicious, malicious }

/// One reputation source's opinion of an indicator of compromise.
class IocVerdict {
  const IocVerdict({
    required this.source,
    required this.severity,
    this.score,
    this.detections = 0,
    this.totalEngines = 0,
    this.details = const {},
  });

  final String source;
  final IocSeverity severity;

  /// A normalised 0-100 confidence score where the source publishes one.
  final int? score;

  /// Number of engines or reporters flagging the indicator.
  final int detections;

  /// Total engines consulted, where the source publishes one.
  final int totalEngines;

  /// Extra source-specific context, rendered as key/value rows in the UI.
  final Map<String, String> details;
}

/// The combined opinion of every reputation source consulted.
class IocReport {
  const IocReport({required this.indicator, required this.verdicts});

  final String indicator;
  final List<IocVerdict> verdicts;

  /// The harshest severity any source returned.
  ///
  /// Deliberately pessimistic: one source calling an indicator malicious
  /// matters more than five calling it clean, because reputation feeds have
  /// very different coverage and a miss is far commoner than a false hit.
  IocSeverity get worstSeverity {
    var worst = IocSeverity.unknown;
    for (final verdict in verdicts) {
      if (verdict.severity.index > worst.index) worst = verdict.severity;
    }
    return worst;
  }

  /// True when at least one source returned a usable opinion.
  bool get hasOpinion =>
      verdicts.any((v) => v.severity != IocSeverity.unknown);
}
