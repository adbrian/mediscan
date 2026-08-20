/// An individual parameter reading stored in the `readings` table.
///
/// Each reading belongs to a [Report] and references a [Parameter].
/// The [entryType] distinguishes between scanned (`scan`) and manually
/// entered (`manual`) readings — manual entries are visually distinguished
/// on trend charts.
class Reading {
  final int? id;
  final int reportId;
  final int parameterId;
  final double value;
  final String unit;
  final double? refLow;
  final double? refHigh;
  final String? refDisplay;
  final String entryType;
  final String createdAt;

  const Reading({
    this.id,
    required this.reportId,
    required this.parameterId,
    required this.value,
    required this.unit,
    this.refLow,
    this.refHigh,
    this.refDisplay,
    this.entryType = 'scan',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'report_id': reportId,
      'parameter_id': parameterId,
      'value': value,
      'unit': unit,
      'ref_low': refLow,
      'ref_high': refHigh,
      'ref_display': refDisplay,
      'entry_type': entryType,
      'created_at': createdAt,
    };
  }

  factory Reading.fromMap(Map<String, dynamic> map) {
    return Reading(
      id: map['id'] as int?,
      reportId: map['report_id'] as int,
      parameterId: map['parameter_id'] as int,
      value: (map['value'] as num).toDouble(),
      unit: map['unit'] as String,
      refLow: (map['ref_low'] as num?)?.toDouble(),
      refHigh: (map['ref_high'] as num?)?.toDouble(),
      refDisplay: map['ref_display'] as String?,
      entryType: (map['entry_type'] as String?) ?? 'scan',
      createdAt: map['created_at'] as String,
    );
  }

  Reading copyWith({
    int? id,
    int? reportId,
    int? parameterId,
    double? value,
    String? unit,
    double? refLow,
    double? refHigh,
    String? refDisplay,
    String? entryType,
    String? createdAt,
  }) {
    return Reading(
      id: id ?? this.id,
      reportId: reportId ?? this.reportId,
      parameterId: parameterId ?? this.parameterId,
      value: value ?? this.value,
      unit: unit ?? this.unit,
      refLow: refLow ?? this.refLow,
      refHigh: refHigh ?? this.refHigh,
      refDisplay: refDisplay ?? this.refDisplay,
      entryType: entryType ?? this.entryType,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Whether the [value] falls within the reference range.
  ///
  /// Returns `true` when both bounds are `null` (no range to violate), or when
  /// the value satisfies any defined bounds.
  bool get isWithinRange {
    if (refLow == null && refHigh == null) return true;
    if (refLow != null && value < refLow!) return false;
    if (refHigh != null && value > refHigh!) return false;
    return true;
  }

  /// Human‑readable status label: `Normal`, `High`, `Low`, or `N/A`.
  ///
  /// Returns `N/A` when no reference range is available to compare against.
  String get statusLabel {
    if (refLow == null && refHigh == null) return 'N/A';
    if (refLow != null && value < refLow!) return 'Low';
    if (refHigh != null && value > refHigh!) return 'High';
    return 'Normal';
  }

  @override
  String toString() =>
      'Reading(parameterId=$parameterId, value=$value $unit, $entryType)';
}
