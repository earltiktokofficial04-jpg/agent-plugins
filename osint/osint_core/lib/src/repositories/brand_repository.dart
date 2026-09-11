import '../models/dns_record.dart';
import '../models/reports.dart';
import '../models/source_result.dart';
import '../models/typosquat.dart';
import '../services/dns_over_https_service.dart';
import '../util/concurrency.dart';
import '../util/typosquat_generator.dart';

/// Finds registered look-alike domains impersonating a brand.
///
/// Candidate generation is local and free; only the registration check costs
/// network requests. The sweep is therefore staged: generate everything, then
/// check a bounded slice, so a phone on mobile data is never asked to make
/// two thousand DNS lookups.
class BrandRepository {
  BrandRepository({
    required DnsOverHttpsService dns,
    TyposquatGenerator generator = const TyposquatGenerator(),
  })  : _dns = dns,
        _generator = generator;

  final DnsOverHttpsService _dns;
  final TyposquatGenerator _generator;

  /// Techniques checked by default, ordered by how strongly a hit suggests
  /// deliberate impersonation rather than coincidence.
  static const List<TyposquatTechnique> highSignalTechniques = [
    TyposquatTechnique.homoglyph,
    TyposquatTechnique.transposition,
    TyposquatTechnique.tldSwap,
    TyposquatTechnique.prefix,
    TyposquatTechnique.omission,
    TyposquatTechnique.replacement,
  ];

  /// Generates candidates for [brandDomain] without touching the network.
  ///
  /// Exposed separately so the UI can show the candidate count and let the
  /// user decide how many to check before any request is made.
  List<TyposquatCandidate> candidatesFor(
    String brandDomain, {
    List<TyposquatTechnique>? techniques,
  }) {
    final allowed = techniques ?? highSignalTechniques;
    return _generator
        .generate(brandDomain)
        .where((candidate) => allowed.contains(candidate.technique))
        .toList();
  }

  /// Checks up to [limit] candidates for [brandDomain] and reports the hits.
  ///
  /// [onProgress] is called after each candidate with the number checked so
  /// far, so a long sweep can drive a progress indicator.
  Future<BrandReport> sweep(
    String brandDomain, {
    List<TyposquatTechnique>? techniques,
    int limit = 150,
    int concurrency = 6,
    void Function(int checked, int total)? onProgress,
  }) async {
    final all = candidatesFor(brandDomain, techniques: techniques);
    final toCheck = all.take(limit).toList();

    if (toCheck.isEmpty) {
      return BrandReport(
        brandDomain: brandDomain,
        candidatesGenerated: all.length,
        notes: const [
          SourceNote(
            source: 'Typosquat',
            ok: false,
            message: 'Could not derive candidates — check the domain format',
          ),
        ],
      );
    }

    var checked = 0;
    final findings = await mapWithConcurrency(
      toCheck,
      (candidate) async {
        final finding = await _check(candidate);
        checked++;
        onProgress?.call(checked, toCheck.length);
        return finding;
      },
      concurrency: concurrency,
    );

    final registered = findings
        .where((finding) => finding != null && finding.isRegistered)
        .cast<TyposquatFinding>()
        .toList();

    // Actionable hits first, then the merely registered ones.
    registered.sort((a, b) {
      if (a.isActionable != b.isActionable) return a.isActionable ? -1 : 1;
      return a.candidate.domain.compareTo(b.candidate.domain);
    });

    return BrandReport(
      brandDomain: brandDomain,
      findings: registered,
      candidatesGenerated: all.length,
      candidatesChecked: toCheck.length,
      notes: [
        SourceNote(
          source: DnsOverHttpsService.sourceName,
          ok: true,
          message: '${toCheck.length} of ${all.length} candidates checked',
        ),
      ],
    );
  }

  /// Resolves one candidate, returning null when the lookup itself failed.
  ///
  /// A failed lookup must not be reported as "not registered": that would turn
  /// a rate limit into a false all-clear, which is the most dangerous kind of
  /// wrong answer this tool could give.
  Future<TyposquatFinding?> _check(TyposquatCandidate candidate) async {
    final aResult = await _dns.resolve(candidate.domain, DnsRecordType.a);

    if (aResult is SourceFailure<List<DnsRecord>>) return null;

    final addresses = [
      for (final record in aResult.valueOrNull ?? const <DnsRecord>[])
        record.data,
    ];

    if (addresses.isNotEmpty) {
      final mx = await _dns.resolve(candidate.domain, DnsRecordType.mx);
      return TyposquatFinding(
        candidate: candidate,
        isRegistered: true,
        addresses: addresses,
        hasMailExchanger: mx is SourceSuccess<List<DnsRecord>>,
      );
    }

    // No A record does not mean unregistered: parked and mail-only domains are
    // common in impersonation campaigns, so fall back to delegation and mail.
    final nsResult = await _dns.resolve(candidate.domain, DnsRecordType.ns);
    if (nsResult is SourceSuccess<List<DnsRecord>>) {
      final mx = await _dns.resolve(candidate.domain, DnsRecordType.mx);
      return TyposquatFinding(
        candidate: candidate,
        isRegistered: true,
        nameservers: [for (final record in nsResult.value) record.data],
        hasMailExchanger: mx is SourceSuccess<List<DnsRecord>>,
      );
    }

    return TyposquatFinding(candidate: candidate, isRegistered: false);
  }
}
