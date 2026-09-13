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
    this.registryServer = '',
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

  /// The RDAP server that answered.
  ///
  /// Worth surfacing: an answer from the TLD's own registry is authoritative,
  /// whereas one relayed by a bootstrap proxy is a copy. In a due-diligence
  /// context the difference is the provenance of the whole record.
  final String registryServer;

  /// Age of the registration at [now], or null when the date is unknown.
  ///
  /// A very young domain is one of the strongest single signals in both
  /// phishing triage and vendor due diligence.
  Duration? ageAt(DateTime now) =>
      registered == null ? null : now.difference(registered!);
}
