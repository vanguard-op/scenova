import 'package:flutter/foundation.dart';

/// The reader's rating of a clip, as `POST /v1/feedback` takes it (`C-012`).
///
/// `helpful` and `notHelpful` answer whether the clip showed the meaning;
/// `wrong` flags a clip that showed the wrong meaning. A negative rating
/// (`notHelpful`, `wrong`) flags the entry for review, and repeated negative
/// ratings from different readers queue it (`FEAT-010`).
enum ClipRating {
  helpful('helpful'),
  notHelpful('not_helpful'),
  wrong('wrong');

  const ClipRating(this.wire);

  /// The value the contract and the event taxonomy use.
  final String wire;

  static ClipRating? fromWire(Object? value) {
    return switch (value) {
      'helpful' => ClipRating.helpful,
      'not_helpful' => ClipRating.notHelpful,
      'wrong' => ClipRating.wrong,
      _ => null,
    };
  }
}

/// Where a rating has got to.
enum FeedbackDelivery {
  /// The rating is on its way to the service.
  sending,

  /// The service recorded it.
  recorded,

  /// The rating is held on the device and goes out when a connection returns
  /// (`FEAT-010`, Edge Cases).
  queued,

  /// The rating could not be recorded. It is retried by the reader.
  failed,
}

/// One rating waiting to reach the service.
///
/// It carries the reader's own idempotency key, so a rating made offline and
/// resent when the connection returns is recorded once rather than twice
/// (`C-012`). The key is minted with the rating and kept with it: a retry
/// reuses it, while a fresh rating of the same clip takes a new one, because the
/// contract refuses a key reused with a different rating (`409`).
@immutable
class PendingFeedback {
  const PendingFeedback({
    required this.lookupId,
    required this.rating,
    required this.clientFeedbackId,
    required this.createdAt,
  });

  /// The lookup the rated clip was served for.
  final String lookupId;

  final ClipRating rating;
  final String clientFeedbackId;
  final DateTime createdAt;

  /// The request body (`C-012`).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'lookupId': lookupId,
    'rating': rating.wire,
    'clientFeedbackId': clientFeedbackId,
  };

  /// The stored form. The device's own shape, kept beside the request body so
  /// the queue survives a relaunch with the key it was minted under.
  Map<String, dynamic> toStoredJson() => <String, dynamic>{
    'lookupId': lookupId,
    'rating': rating.wire,
    'clientFeedbackId': clientFeedbackId,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory PendingFeedback.fromStoredJson(Map<String, dynamic> json) {
    return PendingFeedback(
      lookupId: json['lookupId'] as String? ?? '',
      rating: ClipRating.fromWire(json['rating']) ?? ClipRating.helpful,
      clientFeedbackId: json['clientFeedbackId'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
