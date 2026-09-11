import 'certificate.dart';
import 'dns_record.dart';
import 'registration.dart';
import 'source_result.dart';
import 'target.dart';
import 'typosquat.dart';
import '../services/shodan_service.dart';

/// A note about how one source behaved during a scan.
///
/// Carried alongside every report so the UI can always answer "did this source
/// find nothing, or did it fail?" — the distinction the whole engine is built
/// around.
class SourceNote {
  const SourceNote({
    required this.source,
    required this.ok,
    this.message = '',
    this.needsApiKey = false,
  });

  /// Derives a note from any [SourceResult].
  factory SourceNote.from(SourceResult<Object?> result) => switch (result) {
        SourceSuccess() => SourceNote(source: result.source, ok: true),
        SourceEmpty(:final detail) =>
          SourceNote(source: result.source, ok: true, message: detail),
        SourceFailure(:final message, :final needsApiKey) => SourceNote(
            source: result.source,
            ok: false,
            message: message,
            needsApiKey: needsApiKey,
          ),
      };

  final String source;
  final bool ok;
  final String message;
  final bool needsApiKey;
}

/// The result of an infrastructure recon scan.
class ReconReport {
  const ReconReport({
    required this.target,
    this.dnsRecords = const [],
    this.subdomains = const [],
    this.certificates = const [],
    this.hosts = const {},
    this.notes = const [],
  });

  final Target target;
  final List<DnsRecord> dnsRecords;

  /// Hosts discovered from Certificate Transparency logs.
  final List<String> subdomains;

  final List<CtCertificate> certificates;

  /// Shodan's view of each resolved IP, when a Shodan key is configured.
  final Map<String, ShodanHost> hosts;

  final List<SourceNote> notes;

  /// Every distinct IP address the target's A and AAAA records point at.
  List<String> get addresses => <String>{
        for (final record in dnsRecords)
          if (record.type == DnsRecordType.a ||
              record.type == DnsRecordType.aaaa)
            record.data,
      }.toList();
}

/// The result of a corporate due-diligence lookup.
class DueDiligenceReport {
  const DueDiligenceReport({
    required this.target,
    this.registration,
    this.dnsRecords = const [],
    this.certificateIssuers = const [],
    this.subdomainCount = 0,
    this.notes = const [],
  });

  final Target target;
  final DomainRegistration? registration;
  final List<DnsRecord> dnsRecords;

  /// Distinct CAs that have issued for this domain, newest issuance first.
  final List<String> certificateIssuers;

  final int subdomainCount;
  final List<SourceNote> notes;

  /// Mail, SPF and DMARC posture derived from the TXT and MX records.
  ///
  /// A domain that sends mail with no SPF or DMARC is both a security finding
  /// and, in a vendor assessment, a signal of how the organisation is run.
  MailPosture get mailPosture {
    final txt = [
      for (final record in dnsRecords)
        if (record.type == DnsRecordType.txt) record.data.toLowerCase(),
    ];
    return MailPosture(
      hasMx: dnsRecords.any((r) => r.type == DnsRecordType.mx),
      hasSpf: txt.any((value) => value.startsWith('v=spf1')),
      hasDmarc: txt.any((value) => value.startsWith('v=dmarc1')),
    );
  }
}

/// Mail authentication posture summarised from DNS.
class MailPosture {
  const MailPosture({
    required this.hasMx,
    required this.hasSpf,
    required this.hasDmarc,
  });

  final bool hasMx;
  final bool hasSpf;
  final bool hasDmarc;

  /// True when the domain accepts mail but publishes no SPF record.
  bool get sendsMailUnauthenticated => hasMx && !hasSpf;
}

/// The result of a brand-protection sweep.
class BrandReport {
  const BrandReport({
    required this.brandDomain,
    this.findings = const [],
    this.candidatesGenerated = 0,
    this.candidatesChecked = 0,
    this.notes = const [],
  });

  final String brandDomain;

  /// Candidates that turned out to be registered.
  final List<TyposquatFinding> findings;

  final int candidatesGenerated;
  final int candidatesChecked;
  final List<SourceNote> notes;

  /// Registered look-alikes that resolve or can receive mail.
  List<TyposquatFinding> get actionable =>
      findings.where((finding) => finding.isActionable).toList();
}
