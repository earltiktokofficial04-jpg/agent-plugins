import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

/// Builds a resolver answering from a name+type keyed map.
///
/// Keys are `<name>|<type-code>`; anything unlisted returns NXDOMAIN.
MailSecurityService _service(Map<String, List<String>> zone) {
  return MailSecurityService(
    dns: DnsOverHttpsService(
      client: MockClient((request) async {
        final params = request.url.queryParameters;
        final key = '${params['name']}|${params['type']}';
        final answers = zone[key];
        if (answers == null || answers.isEmpty) {
          return http.Response(jsonEncode({'Status': 3}), 200);
        }
        return http.Response(
          jsonEncode({
            'Status': 0,
            'Answer': [
              for (final data in answers)
                {
                  'name': params['name'],
                  'type': int.parse(params['type']!),
                  'TTL': 60,
                  'data': data,
                },
            ],
          }),
          200,
        );
      }),
    ),
  );
}

const _mx = '15';
const _txt = '16';
const _tlsa = '52';

Future<MailSecurityPosture> _evaluate(Map<String, List<String>> zone) async {
  final result = await _service(zone).evaluate(Target.parse('example.com'));
  return result.valueOrNull!;
}

void main() {
  group('SPF parsing', () {
    test('reads the enforcing qualifier', () async {
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 ip4:192.0.2.0/24 -all'],
      });
      expect(posture.spf!.qualifier, SpfQualifier.fail);
      expect(posture.spf!.enforces, isTrue);
      expect(posture.findings.any((f) => f.title.contains('SPF')), isFalse);
    });

    test('flags +all as worse than no record', () async {
      // "+all" authorises the entire internet to send as the domain.
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 +all'],
      });
      expect(posture.spf!.authorisesEveryone, isTrue);
      final finding = posture.findings.firstWhere(
        (f) => f.title.contains('every sender'),
      );
      expect(finding.severity, MailFindingSeverity.high);
    });

    test('treats a bare "all" as +all', () async {
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 all'],
      });
      expect(posture.spf!.qualifier, SpfQualifier.pass);
    });

    test('distinguishes softfail and neutral from enforcement', () async {
      final soft = await _evaluate({
        'example.com|$_txt': ['v=spf1 ~all'],
      });
      expect(soft.spf!.qualifier, SpfQualifier.softFail);
      expect(soft.spf!.enforces, isFalse);

      final neutral = await _evaluate({
        'example.com|$_txt': ['v=spf1 ?all'],
      });
      expect(neutral.spf!.qualifier, SpfQualifier.neutral);
    });

    test('picks the SPF record out of unrelated TXT records', () async {
      final posture = await _evaluate({
        'example.com|$_txt': [
          'google-site-verification=abc123',
          'MS=ms12345678',
          'v=spf1 include:_spf.google.com -all',
        ],
      });
      expect(posture.spf, isNotNull);
      expect(posture.spf!.includes, ['_spf.google.com']);
    });

    test('reports no SPF record as a high-severity finding', () async {
      final posture = await _evaluate({
        'example.com|$_mx': ['10 mail.example.com.'],
      });
      expect(posture.spf, isNull);
      final finding = posture.findings.firstWhere(
        (f) => f.title == 'No SPF record',
      );
      expect(finding.severity, MailFindingSeverity.high);
      expect(finding.detail, contains('anyone can send as it'));
    });
  });

  group('SPF lookup counting', () {
    test('counts the querying mechanisms in a flat record', () async {
      // a, mx, and one include = 3.
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 a mx include:spf.partner.test -all'],
      });
      expect(posture.spf!.lookupCount, 3);
      expect(posture.spf!.exceedsLookupLimit, isFalse);
    });

    test('follows includes recursively', () async {
      // Counting only the top level would say 1 and miss the real cost.
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 include:a.test -all'],
        'a.test|$_txt': ['v=spf1 include:b.test a mx -all'],
        'b.test|$_txt': ['v=spf1 a a a -all'],
      });
      // 1 (include a.test) + 3 (include b.test, a, mx) + 3 (a a a) = 7
      expect(posture.spf!.lookupCount, 7);
    });

    test('flags a record over the RFC 7208 ten-lookup limit', () async {
      // The commonest invisible SPF fault: the record is well-formed and
      // looks fine, but receivers must permerror on it, so it does nothing.
      final posture = await _evaluate({
        'example.com|$_txt': [
          'v=spf1 a mx ptr exists:x.test include:a.test include:b.test '
              'include:c.test -all',
        ],
        'a.test|$_txt': ['v=spf1 a mx a mx -all'],
        'b.test|$_txt': ['v=spf1 a -all'],
        'c.test|$_txt': ['v=spf1 a -all'],
      });
      expect(posture.spf!.lookupCount, greaterThan(10));
      expect(posture.spf!.exceedsLookupLimit, isTrue);

      final finding = posture.findings.firstWhere(
        (f) => f.title.contains('ten-lookup limit'),
      );
      expect(finding.severity, MailFindingSeverity.high);
      expect(finding.detail, contains('not working at all'));
    });

    test('survives an include loop without hanging', () async {
      // Malformed records loop; without the seen-set this would recurse
      // until the stack or the budget gave out.
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 include:a.test -all'],
        'a.test|$_txt': ['v=spf1 include:b.test -all'],
        'b.test|$_txt': ['v=spf1 include:a.test -all'],
      });
      expect(posture.spf!.lookupCount, lessThan(20));
    });

    test('counts a redirect as a lookup', () async {
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 redirect=spf.partner.test'],
        'spf.partner.test|$_txt': ['v=spf1 a mx -all'],
      });
      expect(posture.spf!.lookupCount, 3);
      expect(posture.spf!.redirect, 'spf.partner.test');
    });
  });

  group('DMARC parsing', () {
    test('reads policy, subdomain policy, pct and reporting', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': [
          'v=DMARC1; p=reject; sp=quarantine; pct=50; '
              'rua=mailto:d@example.com; ruf=mailto:f@example.com',
        ],
      });
      final dmarc = posture.dmarc!;
      expect(dmarc.policy, DmarcPolicy.reject);
      expect(dmarc.subdomainPolicy, DmarcPolicy.quarantine);
      expect(dmarc.percentage, 50);
      expect(dmarc.hasAggregateReporting, isTrue);
      expect(dmarc.hasForensicReporting, isTrue);
    });

    test('defaults subdomain policy to the main policy', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=reject'],
      });
      expect(posture.dmarc!.subdomainPolicy, isNull);
      expect(posture.dmarc!.effectiveSubdomainPolicy, DmarcPolicy.reject);
      expect(posture.dmarc!.percentage, 100);
    });

    test('flags sp=none as leaving subdomains spoofable', () async {
      // A summary that reads only p= would call this domain protected.
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=reject; sp=none'],
      });
      final finding = posture.findings.firstWhere(
        (f) => f.title.contains('Subdomains are exempt'),
      );
      expect(finding.severity, MailFindingSeverity.high);
    });

    test('flags p=none as monitoring only', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=none; rua=mailto:a@b.test'],
      });
      expect(posture.dmarc!.isMonitoringOnly, isTrue);
      expect(
        posture.findings.any((f) => f.title.contains('monitoring only')),
        isTrue,
      );
    });

    test('flags a missing rua', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=reject'],
      });
      expect(
        posture.findings.any((f) => f.title.contains('collects no reports')),
        isTrue,
      );
    });

    test('tolerates odd spacing and case', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['V=DMARC1;P=Reject;  PCT = 100 '],
      });
      expect(posture.dmarc!.policy, DmarcPolicy.reject);
    });
  });

  group('transport security', () {
    test('detects MTA-STS', () async {
      final posture = await _evaluate({
        'example.com|$_mx': ['10 mail.example.com.'],
        '_mta-sts.example.com|$_txt': ['v=STSv1; id=20260101000000Z'],
      });
      expect(posture.hasMtaSts, isTrue);
    });

    test('detects DANE on a mail exchanger', () async {
      final posture = await _evaluate({
        'example.com|$_mx': ['10 mail.example.com.'],
        '_25._tcp.mail.example.com|$_tlsa': ['3 1 1 abcdef'],
      });
      expect(posture.hasDane, isTrue);
    });

    test('flags a mail domain with neither as downgradable', () async {
      final posture = await _evaluate({
        'example.com|$_mx': ['10 mail.example.com.'],
      });
      expect(
        posture.findings.any((f) => f.title.contains('downgraded')),
        isTrue,
      );
    });

    test(
      'does not flag downgrade risk on a domain that takes no mail',
      () async {
        final posture = await _evaluate({
          'example.com|$_txt': ['v=spf1 -all'],
        });
        expect(posture.acceptsMail, isFalse);
        expect(
          posture.findings.any((f) => f.title.contains('downgraded')),
          isFalse,
        );
      },
    );
  });

  group('spoofability', () {
    test('an enforcing SPF alone stops spoofing', () async {
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 ip4:192.0.2.0/24 -all'],
      });
      expect(posture.isSpoofable, isFalse);
    });

    test('an over-limit SPF does not stop spoofing even at -all', () async {
      // The record says -all but receivers never get that far.
      final posture = await _evaluate({
        'example.com|$_txt': [
          'v=spf1 a mx ptr exists:x.test include:a.test include:b.test '
              'include:c.test -all',
        ],
        'a.test|$_txt': ['v=spf1 a mx a mx -all'],
        'b.test|$_txt': ['v=spf1 a -all'],
        'c.test|$_txt': ['v=spf1 a -all'],
      });
      expect(posture.isSpoofable, isTrue);
    });

    test('a DMARC reject policy alone stops spoofing', () async {
      final posture = await _evaluate({
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=reject; rua=mailto:a@b.test'],
      });
      expect(posture.isSpoofable, isFalse);
    });

    test('softfail SPF with p=none leaves the domain spoofable', () async {
      final posture = await _evaluate({
        'example.com|$_txt': ['v=spf1 ~all'],
        '_dmarc.example.com|$_txt': ['v=DMARC1; p=none'],
      });
      expect(posture.isSpoofable, isTrue);
    });
  });

  group('failure handling', () {
    test(
      'a resolver outage is a failure, not a domain with no security',
      () async {
        // Reporting an outage as "no SPF, no DMARC" would manufacture findings
        // out of a network problem.
        final service = MailSecurityService(
          dns: DnsOverHttpsService(
            client: MockClient((_) async => http.Response('', 503)),
          ),
        );
        final result = await service.evaluate(Target.parse('example.com'));
        expect(result, isA<SourceFailure<MailSecurityPosture>>());
      },
    );

    test('declines a non-domain target', () async {
      final result = await _service({}).evaluate(Target.parse('8.8.8.8'));
      expect(result, isA<SourceEmpty<MailSecurityPosture>>());
    });

    test('strips the trailing dot and priority from MX data', () async {
      final posture = await _evaluate({
        'example.com|$_mx': ['10 MAIL.example.com.', '20 backup.example.com.'],
      });
      expect(posture.mailExchangers, [
        'mail.example.com',
        'backup.example.com',
      ]);
    });
  });
}
