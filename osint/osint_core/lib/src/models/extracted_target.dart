import 'target.dart';

/// Where an extracted target was found in an image.
enum TargetOrigin {
  /// Decoded from a QR code or barcode payload.
  code,

  /// Read out of the image's text by OCR.
  text,
}

/// One indicator found in an image, with enough provenance to judge it.
class ExtractedTarget {
  const ExtractedTarget({
    required this.target,
    required this.raw,
    required this.origin,
    this.occurrences = 1,
    this.wasDefanged = false,
    this.fromEmail = false,
  });

  final Target target;

  /// The text exactly as it appeared, before normalisation.
  ///
  /// Kept because OCR misreads are common and the analyst needs to see what
  /// the tool actually read before trusting what it resolved to.
  final String raw;

  final TargetOrigin origin;

  /// How many times this indicator appeared.
  final int occurrences;

  /// True when the text was written defanged, e.g. `hxxp://evil[.]com`.
  ///
  /// Worth surfacing: defanging is deliberate, so its presence is a strong
  /// hint the surrounding text is a threat report rather than an ordinary
  /// document — and that the indicator is already considered hostile.
  final bool wasDefanged;

  /// True when the value came from the domain part of an email address.
  final bool fromEmail;

  ExtractedTarget copyWith({int? occurrences}) => ExtractedTarget(
        target: target,
        raw: raw,
        origin: origin,
        occurrences: occurrences ?? this.occurrences,
        wasDefanged: wasDefanged,
        fromEmail: fromEmail,
      );
}
