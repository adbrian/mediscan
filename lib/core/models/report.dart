/// A scan session stored in the `reports` table.
///
/// Each report represents one lab report scanned or imported by the user.
/// [testDate] is the specimen collection date (single source of truth for
/// chronology). [scanDate] is when the user performed the scan (audit only).
class Report {
  final int? id;
  final String scanDate;
  final String testDate;
  final String? labName;
  final String? notes;

  const Report({
    this.id,
    required this.scanDate,
    required this.testDate,
    this.labName,
    this.notes,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'scan_date': scanDate,
      'test_date': testDate,
      'lab_name': labName,
      'notes': notes,
    };
  }

  factory Report.fromMap(Map<String, dynamic> map) {
    return Report(
      id: map['id'] as int?,
      scanDate: map['scan_date'] as String,
      testDate: map['test_date'] as String,
      labName: map['lab_name'] as String?,
      notes: map['notes'] as String?,
    );
  }

  Report copyWith({
    int? id,
    String? scanDate,
    String? testDate,
    String? labName,
    String? notes,
  }) {
    return Report(
      id: id ?? this.id,
      scanDate: scanDate ?? this.scanDate,
      testDate: testDate ?? this.testDate,
      labName: labName ?? this.labName,
      notes: notes ?? this.notes,
    );
  }

  @override
  String toString() => 'Report(id=$id, testDate=$testDate, lab=$labName)';
}
