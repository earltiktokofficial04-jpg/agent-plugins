import '../models/dns_record.dart';
import '../models/source_result.dart';
import '../models/target.dart';
import 'dns_over_https_service.dart';

/// Which autonomous system announces an address, and who runs it.
class AsnInfo {
  const AsnInfo({
    required this.asn,
    this.prefix = '',
    this.countryCode = '',
    this.registry = '',
    this.allocated,
    this.name = '',
  });

  final int asn;

  /// The BGP prefix the address falls inside.
  final String prefix;

  final String countryCode;

  /// The RIR that allocated the number, e.g. `arin`, `apnic`.
  final String registry;

  final DateTime? allocated;

  /// The AS name and organisation, e.g. `GOOGLE - Google LLC, US`.
  final String name;

  String get label => name.isEmpty ? 'AS$asn' : 'AS$asn — $name';
}

/// Resolves IP-to-ASN through Team Cymru's DNS interface.
///
/// Team Cymru publishes this as TXT records rather than a REST API, which
/// turns out to be an advantage here: it rides the DNS-over-HTTPS transport
/// the tool already uses, so it adds a whole capability — ASN, BGP prefix,
/// allocating registry and AS organisation — without a new dependency, a new
/// key, or a byte of extra APK.
///
/// Team Cymru describe the service as "free, forever", and enforce load by
/// null-routing abusive clients rather than by a published quota. Their terms
/// do not state whether commercial use is permitted, so a commercial
/// deployment should ask them.
class AsnLookupService {
  AsnLookupService({required DnsOverHttpsService dns}) : _dns = dns;

  final DnsOverHttpsService _dns;

  static const String sourceName = 'Team Cymru';

  static const String _originV4 = 'origin.asn.cymru.com';
  static const String _originV6 = 'origin6.asn.cymru.com';
  static const String _asName = 'asn.cymru.com';

  /// Looks up the AS announcing [target], which must be an IP address.
  ///
  /// Two queries: the origin record for the ASN and prefix, then the AS record
  /// for the organisation name. The second is skipped if the first finds
  /// nothing, so an unannounced address costs one lookup rather than two.
  Future<SourceResult<AsnInfo>> lookup(Target target) async {
    if (!target.isIp) {
      return const SourceEmpty(sourceName, 'Only IP addresses are supported');
    }

    final query = target.kind == TargetKind.ipv4
        ? _reverseIpv4(target.value)
        : _reverseIpv6(target.value);
    if (query == null) {
      return const SourceFailure(sourceName, 'Could not build the query name');
    }

    final zone = target.kind == TargetKind.ipv4 ? _originV4 : _originV6;
    final originResult = await _dns.resolve('$query.$zone', DnsRecordType.txt);

    if (originResult is SourceFailure<List<DnsRecord>>) {
      return SourceFailure(sourceName, originResult.message);
    }
    final originRecords = originResult.valueOrNull;
    if (originRecords == null || originRecords.isEmpty) {
      // No origin record means the address is not announced in BGP — bogon
      // space, or simply unrouted. That is a finding, not a failure.
      return const SourceEmpty(
        sourceName,
        'Not announced in BGP — unrouted or bogon space',
      );
    }

    final origin = _parseOrigin(originRecords.first.data);
    if (origin == null) {
      return SourceFailure(
        sourceName,
        'Unexpected origin record: ${originRecords.first.data}',
      );
    }

    final name = await _asNameFor(origin.asn);

    return SourceSuccess(
      sourceName,
      AsnInfo(
        asn: origin.asn,
        prefix: origin.prefix,
        countryCode: origin.countryCode,
        registry: origin.registry,
        allocated: origin.allocated,
        name: name,
      ),
    );
  }

  /// The organisation name for [asn], or an empty string.
  ///
  /// A missing name is not worth failing the whole lookup over: the ASN and
  /// prefix are the useful part.
  Future<String> _asNameFor(int asn) async {
    final result = await _dns.resolve('AS$asn.$_asName', DnsRecordType.txt);
    final records = result.valueOrNull;
    if (records == null || records.isEmpty) return '';
    // "15169 | US | arin | 2000-03-30 | GOOGLE - Google LLC, US"
    final fields = _fields(records.first.data);
    return fields.length >= 5 ? fields[4] : '';
  }

  /// Parses `"15169 | 8.8.8.0/24 | US | arin | 2023-12-28"`.
  static ({
    int asn,
    String prefix,
    String countryCode,
    String registry,
    DateTime? allocated,
  })?
  _parseOrigin(String data) {
    final fields = _fields(data);
    if (fields.length < 2) return null;

    // An address inside overlapping announcements yields several ASNs in one
    // field, space-separated; the first is the most specific origin.
    final asn = int.tryParse(fields[0].split(RegExp(r'\s+')).first);
    if (asn == null) return null;

    return (
      asn: asn,
      prefix: fields[1],
      countryCode: fields.length > 2 ? fields[2] : '',
      registry: fields.length > 3 ? fields[3] : '',
      allocated: fields.length > 4 ? DateTime.tryParse(fields[4]) : null,
    );
  }

  /// Splits a Cymru pipe-delimited record into trimmed fields.
  static List<String> _fields(String data) {
    var text = data.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return text.split('|').map((field) => field.trim()).toList();
  }

  /// `8.8.8.8` becomes `8.8.8.8` reversed: `8.8.8.8`.
  static String? _reverseIpv4(String address) {
    final octets = address.split('.');
    if (octets.length != 4) return null;
    return octets.reversed.join('.');
  }

  /// Expands an IPv6 address to reversed nibbles, as the origin6 zone expects.
  static String? _reverseIpv6(String address) {
    final List<int> bytes;
    try {
      bytes = Uri.parseIPv6Address(address);
    } on FormatException {
      return null;
    }
    final nibbles = <String>[];
    for (final byte in bytes) {
      nibbles.add((byte >> 4).toRadixString(16));
      nibbles.add((byte & 0x0F).toRadixString(16));
    }
    return nibbles.reversed.join('.');
  }
}
