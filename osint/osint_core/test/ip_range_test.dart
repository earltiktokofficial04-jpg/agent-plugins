import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  group('Ipv4Cidr.tryParse', () {
    test('parses a CIDR block and masks the network address', () {
      final block = Ipv4Cidr.tryParse('192.168.1.37/24')!;
      expect(block.prefixLength, 24);
      // The host bits must be cleared, or containment tests silently fail.
      expect(block.network, Ipv4Cidr.ipv4ToInt('192.168.1.0'));
      expect(block.raw, '192.168.1.37/24');
    });

    test('treats a bare address as a /32', () {
      final block = Ipv4Cidr.tryParse('8.8.8.8')!;
      expect(block.prefixLength, 32);
      expect(block.contains('8.8.8.8'), isTrue);
      expect(block.contains('8.8.8.9'), isFalse);
    });

    test('accepts /0 as the whole address space', () {
      final block = Ipv4Cidr.tryParse('0.0.0.0/0')!;
      expect(block.contains('1.2.3.4'), isTrue);
      expect(block.contains('255.255.255.255'), isTrue);
    });

    test('returns null for malformed input rather than throwing', () {
      // Feed files carry comments, blank lines and the occasional broken
      // entry; one bad line must not abort a 20,000-line ingest.
      for (final bad in [
        '',
        '   ',
        'not an ip',
        '1.2.3',
        '1.2.3.4.5',
        '256.1.1.1',
        '1.2.3.4/33',
        '1.2.3.4/-1',
        '1.2.3.4/abc',
      ]) {
        expect(Ipv4Cidr.tryParse(bad), isNull, reason: 'accepted "$bad"');
      }
    });

    test('rejects zero-padded octets', () {
      // 010.1.1.1 is read as octal by some stacks and decimal by others; the
      // ambiguity has been used to slip addresses past naive blocklists.
      expect(Ipv4Cidr.tryParse('010.1.1.1'), isNull);
      expect(Ipv4Cidr.ipv4ToInt('01.2.3.4'), isNull);
    });

    test('containment respects the prefix boundary exactly', () {
      final block = Ipv4Cidr.tryParse('10.0.0.0/8')!;
      expect(block.contains('10.0.0.0'), isTrue);
      expect(block.contains('10.255.255.255'), isTrue);
      expect(block.contains('11.0.0.0'), isFalse);
      expect(block.contains('9.255.255.255'), isFalse);
    });

    test('handles the top of the address space without sign errors', () {
      // 255.255.255.255 exceeds the range of a signed 32-bit int; a shift
      // implemented carelessly wraps negative here.
      final block = Ipv4Cidr.tryParse('255.255.255.0/24')!;
      expect(block.contains('255.255.255.255'), isTrue);
      expect(Ipv4Cidr.ipv4ToInt('255.255.255.255'), 4294967295);
    });
  });

  group('CidrSet', () {
    test('parses a feed file, skipping comments and junk', () {
      final set = CidrSet.parse([
        '; Spamhaus DROP List 2026/09/11',
        '1.10.16.0/20 ; SBL256894',
        '',
        '# another comment style',
        '2.56.192.0/19',
        'garbage line',
        '5.42.199.0/24',
      ]);
      expect(set.length, 3);
      expect(set.contains('1.10.20.5'), isTrue);
      expect(set.contains('2.56.200.1'), isTrue);
      expect(set.contains('8.8.8.8'), isFalse);
    });

    test('strips trailing comments from a data line', () {
      final set = CidrSet.parse(['192.0.2.0/24 ; SBL123']);
      expect(set.length, 1);
      expect(set.contains('192.0.2.7'), isTrue);
    });

    test('returns the most specific matching block', () {
      final set = CidrSet.parse(['10.0.0.0/8', '10.1.2.0/24']);
      expect(set.match('10.1.2.3')!.prefixLength, 24);
      expect(set.match('10.9.9.9')!.prefixLength, 8);
    });

    test('reports empty for a file with no usable entries', () {
      final set = CidrSet.parse(['# header only', '', '   ']);
      expect(set.isEmpty, isTrue);
      expect(set.length, 0);
      expect(set.contains('1.2.3.4'), isFalse);
    });

    test('does not match a non-IPv4 lookup', () {
      final set = CidrSet.parse(['1.2.3.0/24']);
      expect(set.contains('2001:db8::1'), isFalse);
      expect(set.contains('example.com'), isFalse);
    });

    test('handles a large set correctly', () {
      // Real feeds run to tens of thousands of entries; make sure bucketing
      // by prefix length does not lose any of them.
      final lines = [for (var i = 0; i < 5000; i++) '10.${i ~/ 256}.${i % 256}.0/24'];
      final set = CidrSet.parse(lines);
      expect(set.length, 5000);
      expect(set.contains('10.0.0.1'), isTrue);
      expect(set.contains('10.19.135.200'), isTrue);
      expect(set.contains('11.0.0.1'), isFalse);
    });
  });
}
