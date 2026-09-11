/// DNS record types this engine queries.
///
/// The numeric [code] is the IANA resource record type, sent as the `type`
/// parameter of a DNS-over-HTTPS request.
enum DnsRecordType {
  a(1),
  ns(2),
  cname(5),
  soa(6),
  mx(15),
  txt(16),
  aaaa(28),
  caa(257);

  const DnsRecordType(this.code);

  final int code;

  /// The uppercase label used in DNS presentation format, e.g. `AAAA`.
  String get label => name.toUpperCase();

  /// Maps an IANA record type code back to an enum value, or null when the
  /// code is one this engine does not model.
  static DnsRecordType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// A single resolved DNS record.
class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.data,
    required this.ttl,
  });

  final String name;
  final DnsRecordType type;

  /// The record's right-hand side, as returned by the resolver.
  final String data;

  final int ttl;

  @override
  String toString() => '$name ${type.label} $data (TTL $ttl)';
}
