import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

const extractor = TargetExtractor();

List<String> _values(List<ExtractedTarget> found) =>
    found.map((e) => e.target.value).toList();

void main() {
  group('refangText', () {
    test('undoes the bracket conventions threat reports use', () {
      expect(TargetExtractor.refangText('evil[.]com'), 'evil.com');
      expect(
        TargetExtractor.refangText('hxxps://evil[.]com/path'),
        'https://evil.com/path',
      );
      expect(TargetExtractor.refangText('192.168.1[.]1'), '192.168.1.1');
      expect(TargetExtractor.refangText('user[at]evil[.]com'), 'user@evil.com');
      expect(
        TargetExtractor.refangText('hxxp[://]evil(.)com'),
        'http://evil.com',
      );
    });

    test('leaves ordinary text untouched', () {
      const text = 'Visit https://example.com for details.';
      expect(TargetExtractor.refangText(text), text);
      expect(TargetExtractor.looksDefanged(text), isFalse);
    });

    test('detects that defanging was present', () {
      expect(TargetExtractor.looksDefanged('evil[.]com'), isTrue);
    });
  });

  group('fromText — what it finds', () {
    test('extracts a plain domain', () {
      expect(_values(extractor.fromText('go to example.com now')), [
        'example.com',
      ]);
    });

    test('extracts a URL and does not also report its host separately', () {
      // Reporting both would double-count one indicator and make a short
      // report look like two findings.
      final found = extractor.fromText('see https://shop.example.com/cart');
      expect(found, hasLength(1));
      expect(found.single.target.kind, TargetKind.url);
      expect(found.single.target.value, 'shop.example.com');
    });

    test('extracts IPv4 addresses', () {
      expect(_values(extractor.fromText('connect to 203.0.113.7 please')), [
        '203.0.113.7',
      ]);
    });

    test('extracts hashes of each supported length', () {
      final found = extractor.fromText(
        'md5 d41d8cd98f00b204e9800998ecf8427e '
        'sha1 da39a3ee5e6b4b0d3255bfef95601890afd80709 '
        'sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(found, hasLength(3));
      expect(found.map((e) => e.target.kind).toSet(), {
        TargetKind.md5,
        TargetKind.sha1,
        TargetKind.sha256,
      });
    });

    test('takes the domain from an email address and flags it', () {
      final found = extractor.fromText('contact billing@evil-corp.com today');
      expect(found, hasLength(1));
      expect(found.single.target.value, 'evil-corp.com');
      expect(found.single.fromEmail, isTrue);
    });

    test('handles a defanged threat report end to end', () {
      // The screenshot this feature is pointed at.
      final found = extractor.fromText(
        'IOCs: hxxps://login-mybank[.]tk/verify , C2 at 185.220.101[.]5 , '
        'sender phish[at]login-mybank[.]tk',
      );
      expect(_values(found), containsAll(['login-mybank.tk', '185.220.101.5']));
      expect(found.every((e) => e.wasDefanged), isTrue);
    });

    test('counts repeats instead of listing duplicates', () {
      final found = extractor.fromText(
        'evil.com talked to evil.com and then evil.com again',
      );
      expect(found, hasLength(1));
      expect(found.single.occurrences, 3);
    });

    test('keeps the raw text as it was read', () {
      // OCR misreads are common, so the analyst must see what was actually
      // read before trusting what it resolved to.
      final found = extractor.fromText('Go To EXAMPLE.COM');
      expect(found.single.raw, 'EXAMPLE.COM');
      expect(found.single.target.value, 'example.com');
    });

    test('orders results most-specific first', () {
      final found = extractor.fromText(
        'example.com 203.0.113.7 d41d8cd98f00b204e9800998ecf8427e',
      );
      expect(found.map((e) => e.target.kind).toList(), [
        TargetKind.md5,
        TargetKind.ipv4,
        TargetKind.domain,
      ]);
    });
  });

  group('fromText — what it must NOT find', () {
    test('ignores filenames that merely look like hostnames', () {
      // Without a TLD check every filename in a screenshot becomes a domain.
      final found = extractor.fromText(
        'attached report.pdf logo.png backup.zip notes.txt setup.exe',
      );
      expect(found, isEmpty);
    });

    test('ignores version numbers that look like IPs', () {
      // 999 is not a valid octet, so this is a version string, not an address.
      expect(extractor.fromText('nginx 1.24.999.1'), isEmpty);
    });

    test('ignores a hex string of the wrong length', () {
      expect(extractor.fromText('id abc123def456'), isEmpty);
    });

    test('ignores an unknown TLD by default', () {
      expect(extractor.fromText('server.internalthing'), isEmpty);
    });

    test('ignores empty and whitespace input', () {
      expect(extractor.fromText(''), isEmpty);
      expect(extractor.fromText('   \n  '), isEmpty);
    });

    test('does not turn prose punctuation into part of a URL', () {
      final found = extractor.fromText('Read https://example.com/page.');
      expect(found.single.raw, 'https://example.com/page');
    });

    test('does not treat a decimal number as an address', () {
      expect(extractor.fromText('total 1.5 and 3.14159'), isEmpty);
    });
  });

  group('TLD validation', () {
    test('a supplied TLD set widens what counts as a domain', () {
      // The live IANA list has 1,438 entries; the bundled fallback has far
      // fewer, so unusual TLDs need the real list.
      const bundled = TargetExtractor();
      expect(bundled.fromText('brand.zuerich'), isEmpty);

      const withIana = TargetExtractor(knownTlds: {'zuerich'});
      expect(_values(withIana.fromText('brand.zuerich')), ['brand.zuerich']);
    });

    test('the TLD check does not block IPs, hashes or URLs', () {
      const narrow = TargetExtractor(knownTlds: {});
      final found = narrow.fromText(
        '203.0.113.7 https://weird.internaltld/x '
        'd41d8cd98f00b204e9800998ecf8427e',
      );
      expect(found, hasLength(3));
    });

    test('the bundled set covers the local ccTLDs', () {
      expect(_values(extractor.fromText('wzbgroup.com.my')), [
        'wzbgroup.com.my',
      ]);
      expect(_values(extractor.fromText('example.my')), ['example.my']);
    });
  });

  group('refang can be turned off', () {
    test('defanged text finds nothing when refanging is disabled', () {
      const literal = TargetExtractor(refang: false);
      expect(literal.fromText('evil[.]com'), isEmpty);
    });
  });

  group('fromCode', () {
    test('marks the origin as a scanned code', () {
      final found = extractor.fromCode('https://pay-now.example.com/qr?id=7');
      expect(found.single.origin, TargetOrigin.code);
      expect(found.single.target.value, 'pay-now.example.com');
    });

    test('handles a payload that is not a URL at all', () {
      // Plenty of QR codes carry plain text, vCards or Wi-Fi configs.
      expect(extractor.fromCode('WIFI:S:MyNetwork;T:WPA;P:secret;;'), isEmpty);
      final vcard = extractor.fromCode(
        'BEGIN:VCARD\nFN:Ali\nEMAIL:ali@company.com.my\nEND:VCARD',
      );
      expect(_values(vcard), ['company.com.my']);
    });

    test('finds every link in a multi-link payload', () {
      final found = extractor.fromCode(
        'https://a.example.com and https://b.example.com',
      );
      expect(_values(found), containsAll(['a.example.com', 'b.example.com']));
    });
  });
}
