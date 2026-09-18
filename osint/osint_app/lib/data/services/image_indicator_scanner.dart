import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:osint_core/osint_core.dart';

/// Where the user took the image from.
enum ImageSource2 { camera, gallery }

/// The raw text an image yielded, before any indicator extraction.
class ImageReadout {
  const ImageReadout({
    required this.recognisedText,
    required this.codePayloads,
  });

  /// Everything OCR read, as one block.
  final String recognisedText;

  /// One entry per QR code or barcode decoded.
  final List<String> codePayloads;

  bool get isEmpty => recognisedText.trim().isEmpty && codePayloads.isEmpty;
}

/// Reads text and codes out of an image.
///
/// Behind an interface so the view model can be tested without a camera, a
/// device, or ML Kit — none of which exist in a widget test.
abstract interface class ImageIndicatorScanner {
  /// Prompts for an image and reads it, or returns null if the user cancelled.
  Future<ImageReadout?> readImage(ImageSource2 source);
}

/// The production reader: system image picker plus on-device ML Kit.
///
/// Both recognisers run entirely on the device — no image ever leaves the
/// phone, which matters because the images pointed at this feature are often
/// screenshots of confidential incident reports.
class MlKitImageScanner implements ImageIndicatorScanner {
  MlKitImageScanner({
    ImagePicker? picker,
    TextRecognizer? textRecognizer,
    BarcodeScanner? barcodeScanner,
  }) : _picker = picker ?? ImagePicker(),
       _textRecognizer =
           textRecognizer ??
           TextRecognizer(script: TextRecognitionScript.latin),
       _barcodeScanner = barcodeScanner ?? BarcodeScanner();

  final ImagePicker _picker;
  final TextRecognizer _textRecognizer;
  final BarcodeScanner _barcodeScanner;

  @override
  Future<ImageReadout?> readImage(ImageSource2 source) async {
    final picked = await _picker.pickImage(
      source: source == ImageSource2.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // Screenshots of reports are text-dense; downscaling too far costs OCR
      // accuracy, so only very large camera images are reduced.
      maxWidth: 3000,
      imageQuality: 95,
    );
    if (picked == null) return null;

    final input = InputImage.fromFilePath(picked.path);

    // OCR and barcode decoding are independent passes over the same image.
    final recognised = await _textRecognizer.processImage(input);
    final barcodes = await _barcodeScanner.processImage(input);

    return ImageReadout(
      recognisedText: recognised.text,
      codePayloads: [
        for (final barcode in barcodes)
          if (barcode.rawValue != null && barcode.rawValue!.isNotEmpty)
            barcode.rawValue!,
      ],
    );
  }

  /// Releases the native recognisers.
  Future<void> dispose() async {
    await _textRecognizer.close();
    await _barcodeScanner.close();
  }
}

/// Extracts indicators from a readout.
///
/// Kept separate from the reader so the pure part — deciding what counts as an
/// indicator — stays in osint_core and stays testable.
List<ExtractedTarget> indicatorsFrom(
  ImageReadout readout,
  TargetExtractor extractor,
) {
  final byValue = <String, ExtractedTarget>{};

  // Codes first: a QR payload is a deliberate, machine-readable link, so when
  // the same indicator appears in both it should be attributed to the code
  // rather than to possibly-misread OCR text.
  for (final payload in readout.codePayloads) {
    for (final extracted in extractor.fromCode(payload)) {
      byValue.putIfAbsent(extracted.target.value, () => extracted);
    }
  }
  for (final extracted in extractor.fromText(readout.recognisedText)) {
    byValue.putIfAbsent(extracted.target.value, () => extracted);
  }

  return byValue.values.toList();
}
