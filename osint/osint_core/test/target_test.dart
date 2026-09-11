import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('Target.parse', () {
    test('classifies a plain domain and lowercases it', () {
      final target = Target.parse('  Example.COM  ');
      expect(target.kind, TargetKind.domain);
      expect(target.value, 'example.com');
      expect(target.raw, 'Example.COM');
    });

    test('strips a trailing dot from a fully qualified name', () {
      expect(Target.parse('example.com.').value, 'example.com');
      expect(Target.parse('example.com.').kind, TargetKind.domain);
    });

    test('reduces a URL to its host but records it as a URL', () {
      final target = Target.parse('https://shop.example.com/cart?id=1');
      expect(target.kind, TargetKind.url);
      expect(target.value, 'shop.example.com');
    });

    test('classifies IPv4 and rejects out-of-range octets', () {
      expect(Target.parse('8.8.8.8').kind, TargetKind.ipv4);
      expect(Target.parse('256.1.1.1').kind, isNot(TargetKind.ipv4));
    });

    test('rejects zero-padded IPv4 octets', () {
      // 01.2.3.4 is interpreted inconsistently across resolvers and APIs, so
      // it must not be accepted as a valid address.
      expect(Target.parse('01.2.3.4').kind, isNot(TargetKind.ipv4));
    });

    test('classifies IPv6', () {
      expect(Target.parse('2001:4860:4860::8888').kind, TargetKind.ipv6);
      expect(Target.parse('2001:4860:4860::8888').isIp, isTrue);
    });

    test('classifies hashes by length', () {
      expect(Target.parse('d41d8cd98f00b204e9800998ecf8427e').kind,
          TargetKind.md5);
      expect(
        Target.parse('da39a3ee5e6b4b0d3255bfef95601890afd80709').kind,
        TargetKind.sha1,
      );
      expect(
        Target.parse(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ).kind,
        TargetKind.sha256,
      );
      expect(Target.parse('d41d8cd98f00b204e9800998ecf8427e').isHash, isTrue);
    });

    test('treats a wrong-length hex string as not a hash', () {
      expect(Target.parse('abc123').kind, TargetKind.unknown);
    });

    test('reports unusable input as unknown rather than throwing', () {
      expect(Target.parse('').kind, TargetKind.unknown);
      expect(Target.parse('not a target').kind, TargetKind.unknown);
      expect(Target.parse('example').kind, TargetKind.unknown);
    });

    test('accepts a multi-label subdomain', () {
      expect(Target.parse('a.b.c.example.co.uk').kind, TargetKind.domain);
    });
  });
}
