/// The outcome of querying one OSINT source.
///
/// OSINT lookups fan out across many independent sources, and partial failure
/// is the normal case rather than an exception: a missing API key, a rate
/// limit, or one dead endpoint must not discard the findings of every other
/// source. Every service therefore returns a [SourceResult] instead of
/// throwing, and the UI renders per-source status alongside the data.
sealed class SourceResult<T> {
  const SourceResult(this.source);

  /// Human-readable source name, e.g. `crt.sh`.
  final String source;

  /// The value on success, or null on any failure.
  T? get valueOrNull => switch (this) {
        SourceSuccess<T>(:final value) => value,
        _ => null,
      };
}

/// The source answered and returned usable data.
class SourceSuccess<T> extends SourceResult<T> {
  const SourceSuccess(super.source, this.value);

  final T value;
}

/// The source answered but holds nothing for this target.
///
/// Distinct from a failure: "VirusTotal has never seen this hash" is itself a
/// finding, whereas "VirusTotal rejected the key" is not.
class SourceEmpty<T> extends SourceResult<T> {
  const SourceEmpty(super.source, [this.detail = '']);

  final String detail;
}

/// The source could not be queried, or refused the query.
class SourceFailure<T> extends SourceResult<T> {
  const SourceFailure(super.source, this.message, {this.needsApiKey = false});

  final String message;

  /// True when the only thing missing is a credential, which the UI surfaces
  /// as a prompt to open settings rather than as an error.
  final bool needsApiKey;
}
