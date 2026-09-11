import 'package:osint_core/osint_core.dart';
import 'package:test/test.dart';

void main() {
  const generator = TyposquatGenerator();

  group('splitDomain', () {
    test('splits a single-part suffix', () {
      final split = TyposquatGenerator.splitDomain('example.com');
      expect(split.label, 'example');
      expect(split.suffix, 'com');
    });

    test('keeps a known two-part suffix intact', () {
      // A naive split on the last dot would give a label of "co", generating
      // nonsense candidates like "cp.uk".
      final split = TyposquatGenerator.splitDomain('example.co.uk');
      expect(split.label, 'example');
      expect(split.suffix, 'co.uk');
    });

    test('handles a Malaysian commercial suffix', () {
      final split = TyposquatGenerator.splitDomain('wzbgroup.com.my');
      expect(split.label, 'wzbgroup');
      expect(split.suffix, 'com.my');
    });

    test('takes the registrable label from a subdomain', () {
      final split = TyposquatGenerator.splitDomain('mail.example.com');
      expect(split.label, 'example');
      expect(split.suffix, 'com');
    });
  });

  group('generate', () {
    test('never returns the original domain', () {
      final domains =
          generator.generate('example.com').map((c) => c.domain).toList();
      expect(domains, isNot(contains('example.com')));
    });

    test('returns no duplicate domain/technique pairs', () {
      final candidates = generator.generate('example.com');
      expect(candidates.length, candidates.toSet().length);
    });

    test('produces the expected homoglyph substitutions', () {
      final homoglyphs = generator
          .generate('paypal.com')
          .where((c) => c.technique == TyposquatTechnique.homoglyph)
          .map((c) => c.domain);
      // a -> 4 and l -> 1 are the classic substitutions for this brand.
      expect(homoglyphs, contains('p4ypal.com'));
      expect(homoglyphs, contains('paypa1.com'));
    });

    test('produces adjacent-character transpositions', () {
      final transpositions = generator
          .generate('example.com')
          .where((c) => c.technique == TyposquatTechnique.transposition)
          .map((c) => c.domain);
      expect(transpositions, contains('xeample.com'));
      expect(transpositions, contains('eaxmple.com'));
    });

    test('produces single-character omissions', () {
      final omissions = generator
          .generate('google.com')
          .where((c) => c.technique == TyposquatTechnique.omission)
          .map((c) => c.domain);
      expect(omissions, contains('oogle.com'));
      expect(omissions, contains('googl.com'));
    });

    test('swaps the suffix without touching the label', () {
      final swaps = generator
          .generate('example.com')
          .where((c) => c.technique == TyposquatTechnique.tldSwap)
          .map((c) => c.domain);
      expect(swaps, contains('example.xyz'));
      expect(swaps, contains('example.com.my'));
      expect(swaps, isNot(contains('example.com')));
    });

    test('adds the affixes used in credential phishing', () {
      final prefixed = generator
          .generate('example.com')
          .where((c) => c.technique == TyposquatTechnique.prefix)
          .map((c) => c.domain);
      expect(prefixed, contains('login-example.com'));
      expect(prefixed, contains('example-verify.com'));
    });

    test('only emits labels made of DNS-legal characters', () {
      final legal = RegExp(r'^[a-z0-9-]+$');
      for (final candidate in generator.generate('example.com')) {
        final label = TyposquatGenerator.splitDomain(candidate.domain).label;
        expect(legal.hasMatch(label), isTrue,
            reason: '${candidate.domain} has an illegal label');
      }
    });

    test('never emits a label starting or ending with a hyphen', () {
      // Bitsquatting and hyphenation can both produce these, and they are not
      // registrable domains.
      for (final candidate in generator.generate('example.com')) {
        final label = TyposquatGenerator.splitDomain(candidate.domain).label;
        expect(label.startsWith('-'), isFalse, reason: candidate.domain);
        expect(label.endsWith('-'), isFalse, reason: candidate.domain);
      }
    });

    test('returns nothing for input with no suffix', () {
      expect(generator.generate('localhost'), isEmpty);
      expect(generator.generate(''), isEmpty);
    });

    test('honours a restricted TLD list', () {
      const restricted = TyposquatGenerator(extraTlds: ['net']);
      final swaps = restricted
          .generate('example.com')
          .where((c) => c.technique == TyposquatTechnique.tldSwap)
          .map((c) => c.domain)
          .toList();
      expect(swaps, ['example.net']);
    });
  });
}