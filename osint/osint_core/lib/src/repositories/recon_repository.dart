import '../models/certificate.dart';
import '../models/dns_record.dart';
import '../models/reports.dart';
import '../models/target.dart';
import '../services/crtsh_service.dart';
import '../services/dns_over_https_service.dart';
import '../services/hackertarget_service.dart';
import '../services/otx_service.dart';
import '../services/shodan_service.dart';
import '../services/wayback_service.dart';

/// Builds an attack-surface picture of a domain from passive sources only.
///
/// Nothing here touches the target: records come from a public resolver,
/// hostnames from Certificate Transparency logs, and service banners from
/// Shodan's existing scan data. No packet is sent to the target itself, which
/// keeps the tool usable for third-party assessment without authorisation to
/// scan.
class ReconRepository {
  ReconRepository({
    required DnsOverHttpsService dns,
    required CrtShService crtSh,
    ShodanHostService? shodan,
    HackerTargetService? hackerTarget,
    OtxService? otx,
    WaybackService? wayback,
  })  : _dns = dns,
        _crtSh = crtSh,
        _shodan = shodan,
        _hackerTarget = hackerTarget,
        _otx = otx,
        _wayback = wayback;

  final DnsOverHttpsService _dns;
  final CrtShService _crtSh;
  final ShodanHostService? _shodan;
  final HackerTargetService? _hackerTarget;
  final OtxService? _otx;
  final WaybackService? _wayback;

  /// Record types worth pulling for an apex domain.
  static const List<DnsRecordType> apexRecordTypes = [
    DnsRecordType.a,
    DnsRecordType.aaaa,
    DnsRecordType.ns,
    DnsRecordType.mx,
    DnsRecordType.txt,
    DnsRecordType.soa,
    DnsRecordType.caa,
    DnsRecordType.cname,
  ];

  /// Runs a recon scan against [target].
  ///
  /// When [enrichHosts] is true and a Shodan key is configured, each resolved
  /// address is looked up in Shodan. That costs one API credit per address, so
  /// it is opt-in and capped by [maxHostsToEnrich].
  Future<ReconReport> scan(
    Target target, {
    bool enrichHosts = false,
    int maxHostsToEnrich = 5,
  }) async {
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      return ReconReport(
        target: target,
        notes: const [
          SourceNote(
            source: 'Recon',
            ok: false,
            message: 'Recon requires a domain target',
          ),
        ],
      );
    }

    final notes = <SourceNote>[];

    // Every host-discovery source is independent, so they overlap. Each finds
    // hosts the others miss: Certificate Transparency only knows hosts that
    // were issued a certificate, HackerTarget only hosts seen in DNS, and
    // passive DNS only hosts that resolved at some point in the past.
    final dnsFuture = _resolveApex(target.value);
    final certFuture = _crtSh.certificates(target.value);
    final hostFuture = _hackerTarget?.hostSearch(target.value);
    final passiveFuture = _otx?.passiveDns(target);
    final archiveFuture = _wayback?.urlsFor(target.value);

    final dnsRecords = await dnsFuture;
    final certResult = await certFuture;
    notes.add(SourceNote.from(certResult));

    if (dnsRecords.isEmpty) {
      notes.add(
        const SourceNote(
          source: DnsOverHttpsService.sourceName,
          ok: true,
          message: 'No records resolved',
        ),
      );
    } else {
      notes.add(
        const SourceNote(source: DnsOverHttpsService.sourceName, ok: true),
      );
    }

    final certificates = certResult.valueOrNull ?? const <CtCertificate>[];
    final hosts = <String>{
      ...CrtShService.subdomainsFrom(target.value, certificates),
    };

    final suffix = '.${target.value}';
    bool belongsToTarget(String host) =>
        host == target.value || host.endsWith(suffix);

    if (hostFuture != null) {
      final hostResult = await hostFuture;
      notes.add(SourceNote.from(hostResult));
      for (final record in hostResult.valueOrNull ?? const <HostRecord>[]) {
        if (belongsToTarget(record.hostname)) hosts.add(record.hostname);
      }
    }

    final passiveDns = <PassiveDnsRecord>[];
    if (passiveFuture != null) {
      final passiveResult = await passiveFuture;
      notes.add(SourceNote.from(passiveResult));
      for (final record
          in passiveResult.valueOrNull ?? const <PassiveDnsRecord>[]) {
        passiveDns.add(record);
        if (belongsToTarget(record.hostname)) hosts.add(record.hostname);
      }
    }

    final archivedUrls = <ArchivedUrl>[];
    if (archiveFuture != null) {
      final archiveResult = await archiveFuture;
      notes.add(SourceNote.from(archiveResult));
      archivedUrls.addAll(
        archiveResult.valueOrNull ?? const <ArchivedUrl>[],
      );
    }

    final subdomains = hosts.toList()..sort();

    final shodanHosts = <String, ShodanHost>{};
    final shodan = _shodan;
    if (enrichHosts && shodan != null) {
      final addresses = <String>{
        for (final record in dnsRecords)
          if (record.type == DnsRecordType.a ||
              record.type == DnsRecordType.aaaa)
            record.data,
      }.take(maxHostsToEnrich);

      for (final address in addresses) {
        final result = await shodan.host(Target.parse(address));
        notes.add(SourceNote.from(result));
        final host = result.valueOrNull;
        if (host != null) shodanHosts[address] = host;
      }
    }

    return ReconReport(
      target: target,
      dnsRecords: dnsRecords,
      subdomains: subdomains,
      certificates: certificates,
      hosts: shodanHosts,
      passiveDns: passiveDns,
      archivedUrls: archivedUrls,
      notes: notes,
    );
  }

  Future<List<DnsRecord>> _resolveApex(String domain) =>
      _dns.resolveAll(domain, apexRecordTypes);
}
