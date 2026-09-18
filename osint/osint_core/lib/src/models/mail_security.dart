/// What an SPF record tells receivers to do with mail that fails it.
enum SpfQualifier {
  /// `-all` — reject. The only setting that actually stops spoofing.
  fail,

  /// `~all` — accept but mark. The common half-measure.
  softFail,

  /// `?all` — no opinion. Equivalent to publishing nothing.
  neutral,

  /// `+all` — pass anything. Worse than no record: it authorises the world
  /// to send as this domain.
  pass,

  /// No `all` mechanism at all.
  none,
}

/// A parsed SPF record.
class SpfRecord {
  const SpfRecord({
    required this.raw,
    required this.qualifier,
    this.lookupCount = 0,
    this.includes = const [],
    this.redirect = '',
  });

  final String raw;
  final SpfQualifier qualifier;

  /// DNS-querying mechanisms the record uses.
  ///
  /// RFC 7208 caps these at ten; beyond that a receiver must return permerror,
  /// which means the SPF record silently stops working. It is one of the most
  /// common real faults in otherwise well-configured domains, and it is
  /// invisible unless counted.
  final int lookupCount;

  final List<String> includes;
  final String redirect;

  /// True when the record exceeds the RFC 7208 ten-lookup limit.
  bool get exceedsLookupLimit => lookupCount > 10;

  /// True when the record authorises any sender.
  bool get authorisesEveryone => qualifier == SpfQualifier.pass;

  /// True when failing mail is actually rejected.
  bool get enforces => qualifier == SpfQualifier.fail;
}

/// What a DMARC record asks receivers to do with failing mail.
enum DmarcPolicy { none, quarantine, reject }

/// A parsed DMARC record.
class DmarcRecord {
  const DmarcRecord({
    required this.raw,
    required this.policy,
    this.subdomainPolicy,
    this.percentage = 100,
    this.hasAggregateReporting = false,
    this.hasForensicReporting = false,
  });

  final String raw;
  final DmarcPolicy policy;

  /// `sp=`, which overrides [policy] for subdomains.
  ///
  /// A domain at `p=reject` with `sp=none` leaves every subdomain spoofable,
  /// which is a gap an attacker will find and a summary that only reads `p=`
  /// will miss.
  final DmarcPolicy? subdomainPolicy;

  /// `pct=`. A reject policy at pct=10 rejects one message in ten.
  final int percentage;

  final bool hasAggregateReporting;
  final bool hasForensicReporting;

  /// The policy actually applied to subdomains.
  DmarcPolicy get effectiveSubdomainPolicy => subdomainPolicy ?? policy;

  /// True when the policy is published but not enforced on all mail.
  bool get isMonitoringOnly => policy == DmarcPolicy.none;

  /// True when enforcement is partial.
  bool get isPartiallyApplied => percentage < 100;
}

/// One of the record lookups a full posture depends on.
enum MailCheck { spf, dmarc, mtaSts, dane }

/// How badly a domain's mail authentication is set up.
enum MailFindingSeverity { high, medium, low }

/// One concrete problem with a domain's mail security.
class MailFinding {
  const MailFinding({
    required this.title,
    required this.detail,
    required this.severity,
  });

  final String title;
  final String detail;
  final MailFindingSeverity severity;
}

/// A domain's full mail-authentication posture.
class MailSecurityPosture {
  const MailSecurityPosture({
    required this.domain,
    this.mailExchangers = const [],
    this.spf,
    this.dmarc,
    this.hasMtaSts = false,
    this.mtaStsRecord = '',
    this.hasDane = false,
    this.unresolved = const {},
  });

  final String domain;
  final List<String> mailExchangers;
  final SpfRecord? spf;
  final DmarcRecord? dmarc;

  /// MTA-STS, which stops a downgrade attack on inbound mail delivery.
  final bool hasMtaSts;
  final String mtaStsRecord;

  /// DANE TLSA records on the mail exchangers.
  final bool hasDane;

  /// Checks whose lookup failed rather than came back empty.
  ///
  /// The distinction is the whole point: a rate-limited DMARC query and a
  /// domain with no DMARC record look identical in the data and could not be
  /// more different in meaning. An unresolved check produces no finding, so a
  /// resolver problem never manufactures a security finding.
  final Set<MailCheck> unresolved;

  /// True when [check] could not be evaluated.
  bool isUnresolved(MailCheck check) => unresolved.contains(check);

  bool get acceptsMail => mailExchangers.isNotEmpty;

  /// Everything wrong with this domain's mail setup, worst first.
  ///
  /// Assembled here rather than in the UI so the judgement is testable and
  /// identical wherever the posture is shown.
  List<MailFinding> get findings {
    final found = <MailFinding>[];

    final spfRecord = spf;
    if (spfRecord == null && !isUnresolved(MailCheck.spf)) {
      found.add(
        MailFinding(
          title: 'No SPF record',
          detail: acceptsMail
              ? 'This domain accepts mail but authorises no senders, so '
                    'anyone can send as it.'
              : 'No SPF record published. Even a non-mailing domain should '
                    'publish "v=spf1 -all" to stop spoofing.',
          severity: MailFindingSeverity.high,
        ),
      );
    } else if (spfRecord != null) {
      if (spfRecord.authorisesEveryone) {
        found.add(
          const MailFinding(
            title: 'SPF authorises every sender',
            detail:
                'The record ends in "+all", which tells receivers any '
                'host may send as this domain. This is worse than having no '
                'SPF record at all.',
            severity: MailFindingSeverity.high,
          ),
        );
      } else if (spfRecord.qualifier == SpfQualifier.neutral) {
        found.add(
          const MailFinding(
            title: 'SPF expresses no opinion',
            detail:
                'The record ends in "?all", which is equivalent to '
                'publishing nothing.',
            severity: MailFindingSeverity.medium,
          ),
        );
      } else if (spfRecord.qualifier == SpfQualifier.softFail) {
        found.add(
          const MailFinding(
            title: 'SPF only soft-fails',
            detail:
                'The record ends in "~all", so forged mail is marked '
                'rather than rejected. "-all" is the enforcing setting.',
            severity: MailFindingSeverity.low,
          ),
        );
      }

      if (spfRecord.exceedsLookupLimit) {
        found.add(
          MailFinding(
            title: 'SPF exceeds the ten-lookup limit',
            detail:
                'The record needs ${spfRecord.lookupCount} DNS lookups; RFC '
                '7208 caps this at ten. Receivers must treat it as permerror, '
                'so this SPF record is effectively not working at all.',
            severity: MailFindingSeverity.high,
          ),
        );
      }
    }

    final dmarcRecord = dmarc;
    if (dmarcRecord == null && !isUnresolved(MailCheck.dmarc)) {
      found.add(
        const MailFinding(
          title: 'No DMARC record',
          detail:
              'Without DMARC, receivers have no instruction about mail '
              'that fails SPF or DKIM, and the domain owner sees no reports.',
          severity: MailFindingSeverity.high,
        ),
      );
    } else if (dmarcRecord != null) {
      if (dmarcRecord.isMonitoringOnly) {
        found.add(
          const MailFinding(
            title: 'DMARC is monitoring only',
            detail:
                'The policy is "p=none", so failing mail is still '
                'delivered. Nothing is being blocked.',
            severity: MailFindingSeverity.medium,
          ),
        );
      }
      if (dmarcRecord.effectiveSubdomainPolicy == DmarcPolicy.none &&
          dmarcRecord.policy != DmarcPolicy.none) {
        found.add(
          const MailFinding(
            title: 'Subdomains are exempt from DMARC',
            detail:
                'The record sets "sp=none", so although the domain itself '
                'is protected, every subdomain remains spoofable.',
            severity: MailFindingSeverity.high,
          ),
        );
      }
      if (dmarcRecord.isPartiallyApplied) {
        found.add(
          MailFinding(
            title: 'DMARC applies to only part of the mail',
            detail:
                'pct=${dmarcRecord.percentage}, so the policy is applied '
                'to ${dmarcRecord.percentage}% of failing messages.',
            severity: MailFindingSeverity.medium,
          ),
        );
      }
      if (!dmarcRecord.hasAggregateReporting) {
        found.add(
          const MailFinding(
            title: 'DMARC collects no reports',
            detail:
                'No "rua=" address, so the domain owner never learns who '
                'is sending as them.',
            severity: MailFindingSeverity.low,
          ),
        );
      }
    }

    // Only claim a downgrade risk when both transport checks actually ran.
    if (acceptsMail &&
        !hasMtaSts &&
        !hasDane &&
        !isUnresolved(MailCheck.mtaSts) &&
        !isUnresolved(MailCheck.dane)) {
      found.add(
        const MailFinding(
          title: 'Inbound mail can be downgraded',
          detail:
              'Neither MTA-STS nor DANE is published, so an attacker on '
              'the path can strip TLS from mail being delivered to this '
              'domain.',
          severity: MailFindingSeverity.medium,
        ),
      );
    }

    const rank = {
      MailFindingSeverity.high: 0,
      MailFindingSeverity.medium: 1,
      MailFindingSeverity.low: 2,
    };
    found.sort((a, b) => rank[a.severity]!.compareTo(rank[b.severity]!));
    return found;
  }

  /// True when a check could not be completed, so the picture is partial.
  bool get isIncomplete => unresolved.isNotEmpty;

  /// True when nothing stops a stranger sending mail as this domain.
  ///
  /// Returns false when SPF or DMARC could not be resolved: an unknown
  /// posture must not be reported as a confirmed weakness.
  bool get isSpoofable {
    if (isUnresolved(MailCheck.spf) || isUnresolved(MailCheck.dmarc)) {
      return false;
    }
    final spfRecord = spf;
    final dmarcRecord = dmarc;
    final spfStops =
        spfRecord != null &&
        spfRecord.enforces &&
        !spfRecord.exceedsLookupLimit;
    final dmarcStops =
        dmarcRecord != null && dmarcRecord.policy != DmarcPolicy.none;
    return !spfStops && !dmarcStops;
  }
}
