import 'package:flutter/material.dart';
import 'package:osint_core/osint_core.dart';

/// App theme, built from a single seed so light and dark stay consistent.
abstract final class OsintTheme {
  static const Color _seed = Color(0xFF1F6F8B);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

/// Maps an IOC severity onto a colour from the active scheme.
///
/// Severity is also always rendered with a text label beside the colour, so
/// the meaning never depends on colour vision alone.
Color severityColor(IocSeverity severity, ColorScheme scheme) =>
    switch (severity) {
      IocSeverity.malicious => scheme.error,
      IocSeverity.suspicious => const Color(0xFFB26A00),
      IocSeverity.clean => const Color(0xFF2E7D32),
      IocSeverity.unknown => scheme.onSurfaceVariant,
    };

/// A short human label for a severity.
String severityLabel(IocSeverity severity) => switch (severity) {
      IocSeverity.malicious => 'Malicious',
      IocSeverity.suspicious => 'Suspicious',
      IocSeverity.clean => 'No detections',
      IocSeverity.unknown => 'Unknown',
    };
