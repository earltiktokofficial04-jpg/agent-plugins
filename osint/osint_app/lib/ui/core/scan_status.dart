/// Lifecycle of a scan, driving what each feature screen renders.
enum ScanStatus {
  /// Nothing requested yet.
  idle,

  /// A scan is in flight.
  running,

  /// A scan finished; the report may still be thin if sources had nothing.
  done,

  /// The request could not be started, e.g. the target was unparseable.
  rejected,
}
