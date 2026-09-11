/// The mutation technique that produced a typosquat candidate.
///
/// Reporting the technique matters operationally: a homoglyph hit is far more
/// likely to be a deliberate impersonation attempt than an omission hit, which
/// is often just a legitimate short-form domain.
enum TyposquatTechnique {
  omission,
  repetition,
  transposition,
  replacement,
  insertion,
  homoglyph,
  hyphenation,
  bitsquatting,
  tldSwap,
  prefix,
}

/// A generated domain that resembles the brand being protected.
class TyposquatCandidate {
  const TyposquatCandidate({
    required this.domain,
    required this.technique,
  });

  final String domain;
  final TyposquatTechnique technique;

  @override
  bool operator ==(Object other) =>
      other is TyposquatCandidate &&
      other.domain == domain &&
      other.technique == technique;

  @override
  int get hashCode => Object.hash(domain, technique);

  @override
  String toString() => '$domain (${technique.name})';
}

/// A typosquat candidate after checking whether it is actually in use.
class TyposquatFinding {
  const TyposquatFinding({
    required this.candidate,
    required this.isRegistered,
    this.addresses = const [],
    this.nameservers = const [],
    this.hasMailExchanger = false,
  });

  final TyposquatCandidate candidate;

  /// True when the domain resolves or has delegation records.
  final bool isRegistered;

  final List<String> addresses;
  final List<String> nameservers;

  /// True when the domain can receive mail, which raises the likelihood that
  /// it is being used for credential phishing rather than merely parked.
  final bool hasMailExchanger;

  /// Findings worth a human's attention: registered, and either resolving to
  /// a host or able to receive mail.
  bool get isActionable =>
      isRegistered && (addresses.isNotEmpty || hasMailExchanger);
}
