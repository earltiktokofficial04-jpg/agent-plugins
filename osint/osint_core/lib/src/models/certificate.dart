/// A certificate observed in a public Certificate Transparency log.
///
/// CT logs are append-only and public, which makes them the single most
/// productive passive source for subdomain discovery: any host that has ever
/// been issued a publicly trusted certificate appears here.
class CtCertificate {
  const CtCertificate({
    required this.issuer,
    required this.commonName,
    required this.names,
    required this.notBefore,
    required this.notAfter,
    this.serialNumber = '',
  });

  final String issuer;
  final String commonName;

  /// Every DNS name the certificate covers, including SAN entries.
  final List<String> names;

  final DateTime? notBefore;
  final DateTime? notAfter;
  final String serialNumber;

  /// True when [notAfter] is in the past relative to [now].
  ///
  /// [now] is injected so that this stays deterministic under test.
  bool isExpiredAt(DateTime now) => notAfter != null && notAfter!.isBefore(now);
}
