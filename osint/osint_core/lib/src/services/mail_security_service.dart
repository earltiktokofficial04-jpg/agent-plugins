import '../models/dns_record.dart';
import '../models/mail_security.dart';
import '../models/source_result.dart';
import '../models/target.dart';
import 'dns_over_https_service.dart';

/// Evaluates a domain's mail-authentication posture.
///
/// Needs no new data source: SPF, DMARC, MTA-STS and DANE are all published in
/// DNS, so this is logic over the DNS-over-HTTPS transport already integrated.
class MailSecurityService {
  MailSecurityService({required DnsOverHttpsService dns}) : _dns = dns;

  final DnsOverHttpsService _dns;

  static const String sourceName = 'Mail security';

  /// Ceiling on recursive SPF resolution.
  ///
  /// RFC 7208 caps a record at ten DNS-querying mechanisms, so anything past
  /// that is already broken and there is nothing to learn by resolving
  /// further. The cap also bounds what a hostile or looping record can cost.
  static const int _lookupBudget = 12;

  /// Builds the full posture for [target], which must be a domain.
  Future<SourceResult<MailSecurityPosture>> evaluate(Target target) async {
    if (target.kind != TargetKind.domain && target.kind != TargetKind.url) {
      return const SourceEmpty(sourceName, 'Requires a domain target');
    }
    final domain = target.value;

    // These four are independent, so they overlap.
    final mxFuture = _dns.resolve(domain, DnsRecordType.mx);
    final txtFuture = _dns.resolve(domain, DnsRecordType.txt);
    final dmarcFuture = _dns.resolve('_dmarc.$domain', DnsRecordType.txt);
    final mtaStsFuture = _dns.resolve('_mta-sts.$domain', DnsRecordType.txt);

    final mxResult = await mxFuture;
    final txtResult = await txtFuture;
    final dmarcResult = await dmarcFuture;
    final mtaStsResult = await mtaStsFuture;

    // A resolver that is failing outright must not be reported as a domain
    // with no mail security: that would turn an outage into a finding.
    if (mxResult is SourceFailure<List<DnsRecord>> &&
        txtResult is SourceFailure<List<DnsRecord>>) {
      return SourceFailure(
        sourceName,
        'DNS lookups failed: ${(txtResult as SourceFailure).message}',
      );
    }

    final mailExchangers = [
      for (final record in mxResult.valueOrNull ?? const <DnsRecord>[])
        _hostFromMx(record.data),
    ]..removeWhere((host) => host.isEmpty);

    final spf = await _parseSpf(
      domain,
      txtResult.valueOrNull ?? const <DnsRecord>[],
    );

    final dmarc = _parseDmarc(dmarcResult.valueOrNull ?? const <DnsRecord>[]);

    final mtaStsRecord = _firstMatching(
      mtaStsResult.valueOrNull ?? const <DnsRecord>[],
      'v=stsv1',
    );

    final hasDane = await _hasDane(mailExchangers);

    return SourceSuccess(
      sourceName,
      MailSecurityPosture(
        domain: domain,
        mailExchangers: mailExchangers,
        spf: spf,
        dmarc: dmarc,
        hasMtaSts: mtaStsRecord.isNotEmpty,
        mtaStsRecord: mtaStsRecord,
        hasDane: hasDane,
      ),
    );
  }

  /// `10 mail.example.com.` becomes `mail.example.com`.
  static String _hostFromMx(String data) {
    final parts = data.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '';
    var host = parts.last;
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    return host.toLowerCase();
  }

  static String _firstMatching(List<DnsRecord> records, String prefix) {
    for (final record in records) {
      if (record.data.toLowerCase().startsWith(prefix)) return record.data;
    }
    return '';
  }

  Future<SpfRecord?> _parseSpf(String domain, List<DnsRecord> txt) async {
    final raw = _firstMatching(txt, 'v=spf1');
    if (raw.isEmpty) return null;

    final terms = raw.split(RegExp(r'\s+'));
    final includes = <String>[];
    var redirect = '';
    var qualifier = SpfQualifier.none;

    for (final term in terms) {
      final lower = term.toLowerCase();
      if (lower.startsWith('include:')) {
        includes.add(term.substring(8));
      } else if (lower.startsWith('redirect=')) {
        redirect = term.substring(9);
      } else if (lower.endsWith('all')) {
        qualifier = switch (lower) {
          '-all' => SpfQualifier.fail,
          '~all' => SpfQualifier.softFail,
          '?all' => SpfQualifier.neutral,
          'all' || '+all' => SpfQualifier.pass,
          _ => qualifier,
        };
      }
    }

    final lookups = await _countSpfLookups(domain, raw, 0, {domain});

    return SpfRecord(
      raw: raw,
      qualifier: qualifier,
      lookupCount: lookups,
      includes: includes,
      redirect: redirect,
    );
  }

  /// Counts the DNS-querying mechanisms an SPF record costs, following
  /// `include:` and `redirect=` recursively.
  ///
  /// Counting only the top level understates the total badly — a single
  /// `include:` of a large mail provider routinely pulls in several more — and
  /// it is the total that decides whether receivers give up on the record.
  /// [seen] breaks the loops that malformed records sometimes contain.
  Future<int> _countSpfLookups(
    String domain,
    String record,
    int depth,
    Set<String> seen,
  ) async {
    if (depth > 4) return 0;

    var count = 0;
    final nested = <String>[];

    for (final term in record.split(RegExp(r'\s+'))) {
      final lower = term.toLowerCase();
      // Mechanisms that cost a DNS query, per RFC 7208 s4.6.4.
      if (lower.startsWith('include:')) {
        count++;
        nested.add(term.substring(8));
      } else if (lower.startsWith('redirect=')) {
        count++;
        nested.add(term.substring(9));
      } else if (lower == 'a' ||
          lower.startsWith('a:') ||
          lower.startsWith('a/') ||
          lower == 'mx' ||
          lower.startsWith('mx:') ||
          lower.startsWith('mx/') ||
          lower == 'ptr' ||
          lower.startsWith('ptr:') ||
          lower.startsWith('exists:')) {
        count++;
      }
    }

    for (final target in nested) {
      if (count > _lookupBudget) break;
      if (!seen.add(target)) continue;
      final result = await _dns.resolve(target, DnsRecordType.txt);
      final nestedRaw = _firstMatching(
        result.valueOrNull ?? const <DnsRecord>[],
        'v=spf1',
      );
      if (nestedRaw.isEmpty) continue;
      count += await _countSpfLookups(target, nestedRaw, depth + 1, seen);
    }

    return count;
  }

  static DmarcRecord? _parseDmarc(List<DnsRecord> txt) {
    final raw = _firstMatching(txt, 'v=dmarc1');
    if (raw.isEmpty) return null;

    DmarcPolicy? policyFrom(String value) => switch (value.toLowerCase()) {
      'none' => DmarcPolicy.none,
      'quarantine' => DmarcPolicy.quarantine,
      'reject' => DmarcPolicy.reject,
      _ => null,
    };

    var policy = DmarcPolicy.none;
    DmarcPolicy? subdomainPolicy;
    var percentage = 100;
    var hasRua = false;
    var hasRuf = false;

    for (final tag in raw.split(';')) {
      final parts = tag.split('=');
      if (parts.length < 2) continue;
      final key = parts[0].trim().toLowerCase();
      final value = parts.sublist(1).join('=').trim();

      switch (key) {
        case 'p':
          policy = policyFrom(value) ?? policy;
        case 'sp':
          subdomainPolicy = policyFrom(value);
        case 'pct':
          percentage = int.tryParse(value) ?? 100;
        case 'rua':
          hasRua = value.isNotEmpty;
        case 'ruf':
          hasRuf = value.isNotEmpty;
      }
    }

    return DmarcRecord(
      raw: raw,
      policy: policy,
      subdomainPolicy: subdomainPolicy,
      percentage: percentage,
      hasAggregateReporting: hasRua,
      hasForensicReporting: hasRuf,
    );
  }

  /// True when any mail exchanger publishes a TLSA record for SMTP.
  ///
  /// Only the first few are checked: DANE is configured per-host, but a domain
  /// that has it on its primary MX has it, and querying twenty exchangers to
  /// answer a yes/no question is not worth the requests.
  Future<bool> _hasDane(List<String> mailExchangers) async {
    for (final host in mailExchangers.take(3)) {
      final result = await _dns.resolve('_25._tcp.$host', DnsRecordType.tlsa);
      if (result is SourceSuccess<List<DnsRecord>>) return true;
    }
    return false;
  }
}
