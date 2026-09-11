/// A domain's registration record, as published over RDAP.
///
/// RDAP is the structured, JSON-based successor to WHOIS and needs no API key,
/// which makes it the right default source for registration data.
class DomainRegistration {
  const DomainRegistration({
    required this.domain,
    this.registrar = '',
    this.registered,
    this.expires,
    this.lastChanged,
    this.statuses = const [],
    this.nameservers = const [],
    this.dnssecSigned = false,
  });

  final String domain;
  final String registrar;
  final DateTime? registered;
  final DateTime? expires;
  final DateTime? lastChanged;

  /// EPP status codes, e.g. `clientTransferProhibited`.
  final List<String> statuses;

  final List<String> nameservers;
  final bool dnssecSigned;

  /// Age of the registration at [now], or null when the date is unknown.
  ///
  /// A very young domain is one of the strongest single signals in both
  /// phishing triage and vendor due diligence.
  Duration? ageAt(DateTime now) =>
      registered == null ? null : now.difference(registered!);
}
