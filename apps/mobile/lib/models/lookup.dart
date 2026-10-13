import 'package:flutter/foundation.dart';

/// The lookup wire model, conforming to `C-001` / `C-002`.
///
/// The contract is frozen: field names, the status set, and the sense shape
/// below mirror it exactly. Nothing here is inferred from the page — only the
/// selected word or phrase travels.

/// Whether the selection was a single word or a short phrase.
enum LookupKind {
  word,
  phrase;

  static LookupKind? fromWire(Object? value) {
    return switch (value) {
      'word' => LookupKind.word,
      'phrase' => LookupKind.phrase,
      _ => null,
    };
  }

  String get wire => name;
}

/// The outcome of a lookup.
enum LookupStatus {
  served,
  generating,
  fallback,
  denied,
  empty;

  static LookupStatus fromWire(Object? value) {
    return switch (value) {
      'served' => LookupStatus.served,
      'generating' => LookupStatus.generating,
      'fallback' => LookupStatus.fallback,
      'denied' => LookupStatus.denied,
      'empty' => LookupStatus.empty,
      _ => LookupStatus.fallback,
    };
  }

  String get wire => name;
}

/// A generated or library clip, capped at four seconds at 360p.
@immutable
class Clip {
  const Clip({
    required this.url,
    required this.durationSeconds,
    required this.resolution,
    required this.hasAudio,
  });

  final String url;
  final double durationSeconds;
  final String resolution;
  final bool hasAudio;

  factory Clip.fromJson(Map<String, dynamic> json) {
    return Clip(
      url: json['url'] as String? ?? '',
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0,
      resolution: json['resolution'] as String? ?? '360p',
      hasAudio: json['hasAudio'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'durationSeconds': durationSeconds,
    'resolution': resolution,
    'hasAudio': hasAudio,
  };

  @override
  bool operator ==(Object other) =>
      other is Clip &&
      other.url == url &&
      other.durationSeconds == durationSeconds &&
      other.resolution == resolution &&
      other.hasAudio == hasAudio;

  @override
  int get hashCode => Object.hash(url, durationSeconds, resolution, hasAudio);
}

/// One sense of a word, with its gloss phrase and clip when available.
@immutable
class Sense {
  const Sense({
    required this.senseLabel,
    required this.partOfSpeech,
    required this.glossPhrase,
    this.entryId,
    this.clip,
  });

  final String senseLabel;
  final String partOfSpeech;
  final String glossPhrase;
  final String? entryId;
  final Clip? clip;

  bool get hasClip => clip != null;

  factory Sense.fromJson(Map<String, dynamic> json) {
    final rawClip = json['clip'];
    return Sense(
      senseLabel: json['senseLabel'] as String? ?? '',
      partOfSpeech: json['partOfSpeech'] as String? ?? '',
      glossPhrase: json['glossPhrase'] as String? ?? '',
      entryId: json['entryId'] as String?,
      clip: rawClip is Map<String, dynamic> ? Clip.fromJson(rawClip) : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'senseLabel': senseLabel,
    'partOfSpeech': partOfSpeech,
    'glossPhrase': glossPhrase,
    'entryId': entryId,
    'clip': clip?.toJson(),
  };
}

/// A lookup result, as returned by `POST /v1/lookups` and
/// `GET /v1/lookups/{lookupId}`.
@immutable
class LookupResult {
  const LookupResult({
    required this.lookupId,
    required this.kind,
    required this.rawSelection,
    required this.normalisedLemma,
    required this.status,
    required this.senses,
    required this.notice,
    required this.correlationId,
  });

  final String lookupId;
  final LookupKind kind;
  final String rawSelection;
  final String? normalisedLemma;
  final LookupStatus status;
  final List<Sense> senses;
  final String? notice;
  final String correlationId;

  /// The word as it should be shown: the normalised base form when the service
  /// supplies one, otherwise the selection as received.
  String get displayWord => normalisedLemma ?? rawSelection;

  /// Senses that carry a playable clip.
  List<Sense> get playableSenses =>
      senses.where((sense) => sense.hasClip).toList(growable: false);

  /// The single clip to play when the result is served, if there is one.
  Clip? get primaryClip {
    final playable = playableSenses;
    return playable.isEmpty ? null : playable.first.clip;
  }

  factory LookupResult.fromJson(Map<String, dynamic> json) {
    final rawSenses = json['senses'];
    return LookupResult(
      lookupId: json['lookupId'] as String? ?? '',
      kind: LookupKind.fromWire(json['kind']) ?? LookupKind.word,
      rawSelection: json['rawSelection'] as String? ?? '',
      normalisedLemma: json['normalisedLemma'] as String?,
      status: LookupStatus.fromWire(json['status']),
      senses: rawSenses is List
          ? rawSenses
                .whereType<Map<String, dynamic>>()
                .map(Sense.fromJson)
                .toList(growable: false)
          : const <Sense>[],
      notice: json['notice'] as String?,
      correlationId: json['correlationId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lookupId': lookupId,
    'kind': kind.wire,
    'rawSelection': rawSelection,
    'normalisedLemma': normalisedLemma,
    'status': status.wire,
    'senses': senses.map((sense) => sense.toJson()).toList(growable: false),
    'notice': notice,
    'correlationId': correlationId,
  };
}

/// The platform a lookup originates from (`C-001` request).
enum LookupPlatform {
  android,
  ios;

  String get wire => name;

  /// The platform of the running app. The contract admits `android` and `ios`;
  /// a desktop or web build (used for development viewing) reports `ios` so the
  /// shape stays valid until a native target is present.
  static LookupPlatform current() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return LookupPlatform.android;
    }
    return LookupPlatform.ios;
  }
}

/// The `POST /v1/lookups` request body (`C-001`).
@immutable
class LookupRequest {
  const LookupRequest({
    required this.selection,
    required this.clientLookupId,
    required this.platform,
    required this.locale,
    required this.consentModelProcessing,
  });

  final String selection;
  final String clientLookupId;
  final LookupPlatform platform;
  final String locale;
  final bool consentModelProcessing;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'selection': selection,
    'clientLookupId': clientLookupId,
    'platform': platform.wire,
    'locale': locale,
    'consentModelProcessing': consentModelProcessing,
  };
}
