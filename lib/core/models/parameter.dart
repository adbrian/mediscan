/// Canonical parameter definition stored in the `parameters` table.
///
/// Each parameter represents a measurable health metric (e.g., Fasting Blood
/// Sugar, Hemoglobin). Custom parameters added by the user during confirmation
/// have [isCustom] set to `true`.
class Parameter {
  final int? id;
  final String canonicalName;
  final String displayName;
  final String defaultUnit;
  final double? refLow;
  final double? refHigh;
  final String? refDisplay;
  final String panel;
  final bool isCustom;

  const Parameter({
    this.id,
    required this.canonicalName,
    required this.displayName,
    required this.defaultUnit,
    this.refLow,
    this.refHigh,
    this.refDisplay,
    required this.panel,
    this.isCustom = false,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'canonical_name': canonicalName,
      'display_name': displayName,
      'default_unit': defaultUnit,
      'ref_low': refLow,
      'ref_high': refHigh,
      'ref_display': refDisplay,
      'panel': panel,
      'is_custom': isCustom ? 1 : 0,
    };
  }

  factory Parameter.fromMap(Map<String, dynamic> map) {
    return Parameter(
      id: map['id'] as int?,
      canonicalName: map['canonical_name'] as String,
      displayName: map['display_name'] as String,
      defaultUnit: map['default_unit'] as String,
      refLow: (map['ref_low'] as num?)?.toDouble(),
      refHigh: (map['ref_high'] as num?)?.toDouble(),
      refDisplay: map['ref_display'] as String?,
      panel: map['panel'] as String,
      isCustom: (map['is_custom'] as int?) == 1,
    );
  }

  Parameter copyWith({
    int? id,
    String? canonicalName,
    String? displayName,
    String? defaultUnit,
    double? refLow,
    double? refHigh,
    String? refDisplay,
    String? panel,
    bool? isCustom,
  }) {
    return Parameter(
      id: id ?? this.id,
      canonicalName: canonicalName ?? this.canonicalName,
      displayName: displayName ?? this.displayName,
      defaultUnit: defaultUnit ?? this.defaultUnit,
      refLow: refLow ?? this.refLow,
      refHigh: refHigh ?? this.refHigh,
      refDisplay: refDisplay ?? this.refDisplay,
      panel: panel ?? this.panel,
      isCustom: isCustom ?? this.isCustom,
    );
  }

  @override
  String toString() => 'Parameter($canonicalName, $displayName, $panel)';
}
