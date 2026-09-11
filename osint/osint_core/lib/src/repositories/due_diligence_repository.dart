import '../models/certificate.dart';
import '../models/dns_record.dart';
import '../models/reports.dart';
import '../models/target.dart';
import '../services/crtsh_service.dart';
import '../services/dns_over_https_service.dart';
import '../services/rdap_service.dart';

/// Assembles the public-record profile of an organisation's domain.
///
/// Aimed at vendor assessment and counterparty checks: who registered the
/// domain and when, who runs its DNS and mail, whether mail is authenticated,
/// and how large its certificate footprint is.
class DueDiligenceRepository {
  DueDiligenceRepository({
    required RdapService rdap,
    required DnsOverHttpsService dns,
    required CrtShService crtSh,
  })  : _rdap = rdap,
        _dns = dns,
        _crtSh = crtSh;

  final RdapService _rdap;
  final DnsOverHttpsService _dns;
  final CrtShService _crtSh;

  /// Record types that carry organisational signal.
  static const List<DnsRecordType> profileRecordTypes = [
    DnsRecordType.a,
    DnsRecordType.ns,
    DnsRecordType.mx,
    DnsRecordType.txt,
    DnsRecordType.caa,
  ];

  /// Profiles [target], which must be a domain.
  Future<DueDiligenceReport> profile(Target target) async {
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      return DueDiligenceReport(
        target: target,
        notes: const [
          SourceNote(
            source: 'Due diligence',
            ok: false,
            message: 'Profiling requires a domain target',
          ),
        ],
      );
    }

    final rdapFuture = _rdap.domain(target.value);
    final dnsFuture = _dns.resolveAll(target.value, profileRecordTypes);
    final certFuture = _crtSh.certificates(target.value);

    final rdapResult = await rdapFuture;
    final dnsRecords = await dnsFuture;
    final certResult = await certFuture;

    final certificates = certResult.valueOrNull ?? const <CtCertificate>[];

    return DueDiligenceReport(
      target: target,
      registration: rdapResult.valueOrNull,
      dnsRecords: dnsRecords,
      certificateIssuers: _issuers(certificates),
      subdomainCount:
          CrtShService.subdomainsFrom(target.value, certificates).length,
      notes: [
        SourceNote.from(rdapResult),
        SourceNote(
          source: DnsOverHttpsService.sourceName,
          ok: true,
          message: dnsRecords.isEmpty ? 'No records resolved' : '',
        ),
        SourceNote.from(certResult),
      ],
    );
  }

  /// Distinct issuing CAs, ordered by most recent issuance.
  static List<String> _issuers(List<CtCertificate> certificates) {
    final newestByIssuer = <String, DateTime>{};
    for (final certificate in certificates) {
      final issuer = certificate.issuer;
      if (issuer.isEmpty) continue;
      final seenAt = certificate.notBefore ?? DateTime.utc(1970);
      final existing = newestByIssuer[issuer];
      if (existing == null || seenAt.isAfter(existing)) {
        newestByIssuer[issuer] = seenAt;
      }
    }
    final issuers = newestByIssuer.keys.toList()
      ..sort((a, b) => newestByIssuer[b]!.compareTo(newestByIssuer[a]!));
    return issuers;
  }
}
