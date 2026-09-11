/// The kind of entity an OSINT lookup is being performed against.
///
/// Classification drives which sources a repository can usefully query: a
/// file hash has no DNS records, an IP address has no registration record.
enum TargetKind { domain, ipv4, ipv6, url, md5, sha1, sha256, unknown }

/// A validated, normalised OSINT target.
///
/// Construct via [Target.parse] rather than directly, so that every target in
/// the system has been through the same normalisation.
class Target {
  const Target._(this.raw, this.value, this.kind);

  /// Exactly what the user typed, retained for display.
  final String raw;

  /// The normalised form used when building requests.
  final String value;

  final TargetKind kind;

  /// True when the target is an IP address of either family.
  bool get isIp => kind == TargetKind.ipv4 || kind == TargetKind.ipv6;

  /// True when the target is a file hash of any supported length.
  bool get isHash =>
      kind == TargetKind.md5 ||
      kind == TargetKind.sha1 ||
      kind == TargetKind.sha256;

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');
  static final RegExp _domain = RegExp(
    r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  );

  /// Classifies and normalises [input].
  ///
  /// Lowercases, trims, strips a URL scheme and path when the input is a URL,
  /// and drops a single trailing dot from a fully qualified domain name.
  /// Returns a target of kind [TargetKind.unknown] when nothing matches, so
  /// callers can report the problem rather than handle an exception.
  static Target parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return Target._(input, '', TargetKind.unknown);
    }
    final lower = trimmed.toLowerCase();

    // A URL is recorded as a URL but normalised to its host, which is what
    // every downstream source actually needs.
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final uri = Uri.tryParse(lower);
      final host = uri?.host ?? '';
      if (host.isNotEmpty) {
        return Target._(trimmed, host, TargetKind.url);
      }
      return Target._(trimmed, lower, TargetKind.unknown);
    }

    if (_isIpv4(lower)) return Target._(trimmed, lower, TargetKind.ipv4);
    if (_isIpv6(lower)) return Target._(trimmed, lower, TargetKind.ipv6);

    if (_hex.hasMatch(lower)) {
      switch (lower.length) {
        case 32:
          return Target._(trimmed, lower, TargetKind.md5);
        case 40:
          return Target._(trimmed, lower, TargetKind.sha1);
        case 64:
          return Target._(trimmed, lower, TargetKind.sha256);
      }
    }

    final host = lower.endsWith('.') ? lower.substring(0, lower.length - 1) : lower;
    if (_domain.hasMatch(host)) {
      return Target._(trimmed, host, TargetKind.domain);
    }

    return Target._(trimmed, lower, TargetKind.unknown);
  }

  static bool _isIpv4(String value) {
    final match = _ipv4.firstMatch(value);
    if (match == null) return false;
    for (var i = 1; i <= 4; i++) {
      final octet = int.parse(match.group(i)!);
      if (octet > 255) return false;
      // Reject zero-padded octets such as 01.2.3.4, which resolvers and
      // reputation APIs disagree about how to interpret.
      if (match.group(i)!.length > 1 && match.group(i)!.startsWith('0')) {
        return false;
      }
    }
    return true;
  }

  static bool _isIpv6(String value) {
    if (!value.contains(':')) return false;
    try {
      Uri.parseIPv6Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  String toString() => '$value (${kind.name})';
}
