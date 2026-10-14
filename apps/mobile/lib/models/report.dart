import 'package:flutter/foundation.dart';

/// Why the reader reported a clip, as `POST /v1/reports` takes it (`C-013`).
///
/// The wire value is what the contract and the event taxonomy carry; the label
/// is the reader-facing line in the reason list (`docs/Scenova/screens/05-report-sheet.md`).
enum ReportReason {
  wrongMeaning('wrong_meaning', 'It shows the wrong meaning'),
  offensive('offensive', "It's offensive"),
  lowQuality('low_quality', 'The clip is poor quality'),
  other('other', 'Something else');

  const ReportReason(this.wire, this.label);

  /// The value the contract and the event taxonomy use.
  final String wire;

  /// The line the reader chooses from.
  final String label;

  static ReportReason? fromWire(Object? value) {
    return switch (value) {
      'wrong_meaning' => ReportReason.wrongMeaning,
      'offensive' => ReportReason.offensive,
      'low_quality' => ReportReason.lowQuality,
      'other' => ReportReason.other,
      _ => null,
    };
  }
}

/// Where a report has got to.
enum ReportDelivery {
  /// The report is on its way to the service.
  sending,

  /// The service queued the report for review.
  sent,

  /// The report is held on the device and goes out when a connection returns
  /// (`FEAT-011`, Edge Cases).
  queued,

  /// The reader had already reported this clip, so nothing new was queued
  /// (`C-013`, 409; `FEAT-011`, Edge Cases).
  duplicate,

  /// The report could not be sent. It is retried by the reader.
  failed,
}

/// One report waiting to reach the service.
///
/// It carries the reader's own idempotency key, so a report made offline and
/// resent when the connection returns is recorded once rather than twice
/// (`C-013`, `clientReportId`). The key is minted with the report and kept with
/// it, so a retry reuses it.
@immutable
class PendingReport {
  const PendingReport({
    required this.lookupId,
    required this.reason,
    this.note,
    required this.clientReportId,
    required this.createdAt,
  });

  /// The lookup the reported clip was served for.
  final String lookupId;

  final ReportReason reason;

  /// The reader's optional detail, at most 300 characters (`C-013`).
  final String? note;

  final String clientReportId;
  final DateTime createdAt;

  /// The request body (`C-013`).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'lookupId': lookupId,
    'reason': reason.wire,
    'note': note,
    'clientReportId': clientReportId,
  };

  /// The stored form. The device's own shape, kept beside the request body so
  /// the queue survives a relaunch with the key it was minted under.
  Map<String, dynamic> toStoredJson() => <String, dynamic>{
    'lookupId': lookupId,
    'reason': reason.wire,
    'note': note,
    'clientReportId': clientReportId,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory PendingReport.fromStoredJson(Map<String, dynamic> json) {
    return PendingReport(
      lookupId: json['lookupId'] as String? ?? '',
      reason: ReportReason.fromWire(json['reason']) ?? ReportReason.other,
      note: json['note'] as String?,
      clientReportId: json['clientReportId'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
