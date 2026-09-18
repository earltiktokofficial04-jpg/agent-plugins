import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

DnsRecord _record(DnsRecordType type, String data) =>
    DnsRecord(name: 'example.com', type: type, data: data, ttl: 60);

void main() {
  group('SourceNote.from', () {
    test('marks a success as ok', () {
      const result = SourceSuccess<int>('DNS', 1);
      final note = SourceNote.from(result);
      expect(note.ok, isTrue);
      expect(note.source, 'DNS');
    });

    test('marks an empty result as ok and keeps the detail', () {
      const result = SourceEmpty<int>('DNS', 'NXDOMAIN');
      final note = SourceNote.from(result);
      expect(note.ok, isTrue);
      expect(note.message, 'NXDOMAIN');
    });

    test('marks a failure as not ok and carries the key flag', () {
      const result = SourceFailure<int>(
        'VirusTotal',
        'no key',
        needsApiKey: true,
      );
      final note = SourceNote.from(result);
      expect(note.ok, isFalse);
      expect(note.needsApiKey, isTrue);
      expect(note.message, 'no key');
    });
  });

  group('IocReport', () {
    test('takes the harshest verdict across sources', () {
      // Reputation feeds have very different coverage, so one malicious
      // verdict must outweigh several clean ones.
      const report = IocReport(
        indicator: '1.2.3.4',
        verdicts: [
          IocVerdict(source: 'a', severity: IocSeverity.clean),
          IocVerdict(source: 'b', severity: IocSeverity.malicious),
          IocVerdict(source: 'c', severity: IocSeverity.suspicious),
        ],
      );
      expect(report.worstSeverity, IocSeverity.malicious);
      expect(report.hasOpinion, isTrue);
    });

    test('reports unknown and no opinion when nothing is known', () {
      const report = IocReport(
        indicator: 'x',
        verdicts: [IocVerdict(source: 'a', severity: IocSeverity.unknown)],
      );
      expect(report.worstSeverity, IocSeverity.unknown);
      expect(report.hasOpinion, isFalse);
    });

    test('reports unknown for an empty verdict list', () {
      const report = IocReport(indicator: 'x', verdicts: []);
      expect(report.worstSeverity, IocSeverity.unknown);
      expect(report.hasOpinion, isFalse);
    });
  });

  group('ReconReport', () {
    test('collects distinct addresses from A and AAAA records only', () {
      final report = ReconReport(
        target: Target.parse('example.com'),
        dnsRecords: [
          _record(DnsRecordType.a, '1.2.3.4'),
          _record(DnsRecordType.a, '1.2.3.4'),
          _record(DnsRecordType.aaaa, '2606:2800::1'),
          _record(DnsRecordType.mx, '10 mail.example.com'),
          _record(DnsRecordType.ns, 'ns1.example.com'),
        ],
      );
      expect(report.addresses, ['1.2.3.4', '2606:2800::1']);
    });
  });

  group('DueDiligenceReport.mailSecurity', () {
    test('carries the mail posture the service produced', () {
      // The judgement itself lives in MailSecurityService and is tested
      // there; the report only has to carry it through intact.
      final report = DueDiligenceReport(
        target: Target.parse('example.com'),
        mailSecurity: const MailSecurityPosture(
          domain: 'example.com',
          mailExchangers: ['mail.example.com'],
        ),
      );
      expect(report.mailSecurity!.acceptsMail, isTrue);
      expect(report.mailSecurity!.isSpoofable, isTrue);
    });

    test('a null posture means not evaluated, not "no protection"', () {
      final report = DueDiligenceReport(target: Target.parse('example.com'));
      expect(report.mailSecurity, isNull);
    });
  });

  group('BrandReport', () {
    test('separates actionable findings from merely registered ones', () {
      const live = TyposquatFinding(
        candidate: TyposquatCandidate(
          domain: 'exarnple.com',
          technique: TyposquatTechnique.homoglyph,
        ),
        isRegistered: true,
        addresses: ['1.2.3.4'],
      );
      const parked = TyposquatFinding(
        candidate: TyposquatCandidate(
          domain: 'exampel.com',
          technique: TyposquatTechnique.transposition,
        ),
        isRegistered: true,
      );

      const report = BrandReport(
        brandDomain: 'example.com',
        findings: [live, parked],
      );
      expect(report.actionable, [live]);
    });
  });
}
