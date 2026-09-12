import '../models/dns_record.dart';
import '../models/reports.dart';
import '../models/source_result.dart';
import '../models/typosquat.dart';
import '../services/dns_over_https_service.dart';
import '../services/iana_registry_service.dart';
import '../util/concurrency.dart';
import '../util/typosquat_generator.dart';

/// How wide a namespace sweep should reach.
enum SweepBreadth {
  /// The TLDs impersonation most often uses, plus the brand's own.
  focused,

  /// Every delegated top-level domain.
  allTlds,

  /// Every public suffix, including second-level namespaces such as
  /// `com.my` and `co.uk`.
  allSuffixes,
}

/// Sweeps a brand name across registrable namespaces.
///
/// Distinct from [BrandRepository], which mutates the *label* and holds the
/// suffix fixed. This holds the label fixed and varies the *suffix*, which is
/// how a brand ends up squatted at `brand.tk` or `brand.com.my` while
/// `brand.com` is safely owned.
///
/// The namespace lists come from IANA and the Public Suffix List, so breadth
/// is bounded by what actually exists rather than by a hard-coded guess.
class TldSweepRepository {
  TldSweepRepository({
    required DnsOverHttpsService dns,
    required IanaRegistryService registry,
  })  : _dns = dns,
        _registry = registry;

  final DnsOverHttpsService _dns;
  final IanaRegistryService _registry;

  List<String>? _tldCache;
  List<String>? _suffixCache;

  /// Loads and caches the namespace list for [breadth].
  ///
  /// Returns an empty list when the registry could not be fetched, so callers
  /// report a source failure rather than silently sweeping nothing.
  Future<List<String>> namespacesFor(SweepBreadth breadth) async {
    switch (breadth) {
      case SweepBreadth.focused:
        return TyposquatGenerator.defaultTlds;

      case SweepBreadth.allTlds:
        final cached = _tldCache;
        if (cached != null) return cached;
        final result = await _registry.tlds();
        final tlds = result.valueOrNull ?? const <String>[];
        if (tlds.isNotEmpty) _tldCache = tlds;
        return tlds;

      case SweepBreadth.allSuffixes:
        final cached = _suffixCache;
        if (cached != null) return cached;
        final result = await _registry.publicSuffixes();
        final suffixes = result.valueOrNull ?? const <String>[];
        if (suffixes.isNotEmpty) _suffixCache = suffixes;
        return suffixes;
    }
  }

  /// Sweeps [brandDomain]'s label across namespaces of the given [breadth].
  ///
  /// [limit] caps the work: the full Public Suffix List is over ten thousand
  /// namespaces, which is minutes of lookups and a real amount of mobile data,
  /// so the caller chooses how much of it to spend.
  Future<BrandReport> sweep(
    String brandDomain, {
    SweepBreadth breadth = SweepBreadth.allTlds,
    int limit = 500,
    int concurrency = 10,
    void Function(int checked, int total)? onProgress,
  }) async {
    final split = TyposquatGenerator.splitDomain(
      brandDomain.trim().toLowerCase(),
    );
    final label = split.label;
    if (label.isEmpty || split.suffix.isEmpty) {
      return BrandReport(
        brandDomain: brandDomain,
        notes: const [
          SourceNote(
            source: 'Namespace sweep',
            ok: false,
            message: 'Could not read a brand label from that domain',
          ),
        ],
      );
    }

    final namespaces = await namespacesFor(breadth);
    if (namespaces.isEmpty) {
      return BrandReport(
        brandDomain: brandDomain,
        notes: const [
          SourceNote(
            source: 'Namespace registry',
            ok: false,
            message: 'Namespace list could not be fetched',
          ),
        ],
      );
    }

    // The brand's own namespace is not a squat, so it is excluded rather than
    // reported as a finding against itself.
    final candidates = <TyposquatCandidate>[
      for (final namespace in namespaces)
        if (namespace != split.suffix)
          TyposquatCandidate(
            domain: '$label.$namespace',
            technique: TyposquatTechnique.tldSwap,
          ),
    ];

    final toCheck = candidates.take(limit).toList();
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
        .toList()
      ..sort((a, b) {
        if (a.isActionable != b.isActionable) return a.isActionable ? -1 : 1;
        return a.candidate.domain.compareTo(b.candidate.domain);
      });

    return BrandReport(
      brandDomain: brandDomain,
      findings: registered,
      candidatesGenerated: candidates.length,
      candidatesChecked: toCheck.length,
      notes: [
        SourceNote(
          source: 'Namespace sweep',
          ok: true,
          message: '${toCheck.length} of ${candidates.length} namespaces '
              'checked (${breadth.name})',
        ),
      ],
    );
  }

  /// Resolves one candidate; null when the lookup itself failed.
  ///
  /// As in the typosquat sweep, a failed lookup is never reported as an
  /// unregistered domain: that would turn a rate limit into a false all-clear.
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

    final nsResult = await _dns.resolve(candidate.domain, DnsRecordType.ns);
    if (nsResult is SourceSuccess<List<DnsRecord>>) {
      return TyposquatFinding(
        candidate: candidate,
        isRegistered: true,
        nameservers: [for (final record in nsResult.value) record.data],
      );
    }

    return TyposquatFinding(candidate: candidate, isRegistered: false);
  }
}
