import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryTeal = Color(0xFF00897B);
  static const Color secondaryBlue = Color(0xFF1565C0);
  static const Color successGreen = Color(0xFF4CAF50);
  static const Color errorRed = Color(0xFFE53935);
  static const Color warningAmber = Color(0xFFFFB300);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      // V1 ships the platform default face; the Inter assets were never
      // sourced, and naming a missing family here would fall back silently.
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryTeal,
        primary: primaryTeal,
        secondary: secondaryBlue,
        error: errorRed,
        brightness: Brightness.light,
        surface: const Color(0xFFF5F5F5),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      extensions: const <ThemeExtension<dynamic>>[
        MedicalColors(
          normalValue: successGreen,
          highValue: errorRed,
          lowValue: secondaryBlue,
          referenceRangeBand: Color(0x334CAF50),
        ),
      ],
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      // V1 ships the platform default face; the Inter assets were never
      // sourced, and naming a missing family here would fall back silently.
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryTeal,
        primary: primaryTeal,
        secondary: secondaryBlue,
        error: errorRed,
        brightness: Brightness.dark,
        surface: const Color(0xFF1E1E1E),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF2C2C2C),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      extensions: const <ThemeExtension<dynamic>>[
        MedicalColors(
          normalValue: successGreen,
          highValue: errorRed,
          lowValue: secondaryBlue,
          referenceRangeBand: Color(0x334CAF50),
        ),
      ],
    );
  }
}

class MedicalColors extends ThemeExtension<MedicalColors> {
  final Color? normalValue;
  final Color? highValue;
  final Color? lowValue;
  final Color? referenceRangeBand;

  const MedicalColors({
    required this.normalValue,
    required this.highValue,
    required this.lowValue,
    required this.referenceRangeBand,
  });

  @override
  MedicalColors copyWith({
    Color? normalValue,
    Color? highValue,
    Color? lowValue,
    Color? referenceRangeBand,
  }) {
    return MedicalColors(
      normalValue: normalValue ?? this.normalValue,
      highValue: highValue ?? this.highValue,
      lowValue: lowValue ?? this.lowValue,
      referenceRangeBand: referenceRangeBand ?? this.referenceRangeBand,
    );
  }

  @override
  MedicalColors lerp(ThemeExtension<MedicalColors>? other, double t) {
    if (other is! MedicalColors) {
      return this;
    }
    return MedicalColors(
      normalValue: Color.lerp(normalValue, other.normalValue, t),
      highValue: Color.lerp(highValue, other.highValue, t),
      lowValue: Color.lerp(lowValue, other.lowValue, t),
      referenceRangeBand: Color.lerp(referenceRangeBand, other.referenceRangeBand, t),
    );
  }
}
