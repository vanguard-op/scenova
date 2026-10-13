import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/analytics_event.dart';
import '../models/entitlement.dart';
import '../models/lookup.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import '../services/lookup_api.dart';

/// The state of the in-context clip view
/// (`docs/Scenova/screens/03-clip-view.md` → States).
enum ClipPhase {
  loading,
  generating,
  playing,
  senseChoice,
  fallback,
  denied,
  empty,
  offline,
  allowanceExhausted,
  error,
}

/// How the reader marked a clip.
enum FeedbackMark { helpful, notHelpful }

/// Drives one clip view from the moment a word arrives to the moment a clip
/// plays.
///
/// The controller owns the lookup lifecycle: it asks the service, polls while a
/// clip generates, tells the reader once the wait passes the threshold, saves
/// the lookup to device history, and degrades to history when the device is
/// offline. A second selection while the view is open updates it in place
/// rather than opening a second view.
class ClipViewController extends ChangeNotifier {
  ClipViewController({
    required this.services,
    required CaptureSelection selection,
    this.source = LookupSource.typed,
    Duration? pollInterval,
    Duration? noticeThreshold,
    Duration? pollTimeout,
  }) : _pollInterval = pollInterval ?? AppConfig.lookupPollInterval,
       _noticeThreshold =
           noticeThreshold ?? AppConfig.generatingNoticeThreshold,
       _pollTimeout = pollTimeout ?? AppConfig.lookupPollTimeout {
    _selection = selection;
  }

  final ScenovaServices services;

  /// Where this lookup entered the app, for `lookup_started`'s `source`.
  final LookupSource source;
  final Duration _pollInterval;
  final Duration _noticeThreshold;
  final Duration _pollTimeout;

  late CaptureSelection _selection;
  LookupResult? _result;
  Sense? _chosenSense;
  ClipPhase _phase = ClipPhase.loading;
  Entitlement _entitlement = Entitlement.unmeteredGuest;
  String? _errorMessage;
  Timer? _pollTimer;
  int _generatingPolls = 0;
  bool _disposed = false;

  bool _playing = false;
  bool _willNotify = false;
  bool _noticeShown = false;
  bool _fromHistory = false;
  FeedbackMark? _feedback;

  CaptureSelection get selection => _selection;
  LookupResult? get result => _result;
  Sense? get chosenSense => _chosenSense;
  ClipPhase get phase => _phase;
  Entitlement get entitlement => _entitlement;
  String? get errorMessage => _errorMessage;
  bool get playing => _playing;
  bool get willNotify => _willNotify;
  FeedbackMark? get feedback => _feedback;

  /// The word to show, preferring the result's normalised form.
  String get word => _result?.displayWord ?? _selection.text;

  /// The gloss phrase to show, from the chosen sense or the first sense.
  String? get phrase {
    final sense = _chosenSense ?? _firstSense;
    final value = sense?.glossPhrase;
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The clip that would play.
  Clip? get clip => _chosenSense?.clip ?? _result?.primaryClip;

  /// The note shown with the word and phrase.
  ///
  /// It carries any reader-facing advisory the service sends, including the
  /// best-guess note when the word is outside the sense inventory. The sense
  /// label is a human label and is never read as a signal.
  String? get note => _result?.notice;

  Sense? get _firstSense =>
      (_result?.senses.isEmpty ?? true) ? null : _result!.senses.first;

  /// Whether the notice SnackBar should be raised for this change.
  bool get shouldShowGeneratingNotice =>
      _noticeShown && _phase == ClipPhase.generating && !_willNotify;

  /// Loads the selection. Called on mount and on reuse.
  ///
  /// [announceStart] emits `lookup_started`; a retry of the same lookup passes
  /// false so the funnel counts the lookup once.
  Future<void> load({bool announceStart = true}) async {
    _cancelPoll();
    _playing = false;
    _feedback = null;
    _willNotify = false;
    _noticeShown = false;
    _fromHistory = false;
    _errorMessage = null;
    _chosenSense = null;
    _result = null;
    _setPhase(ClipPhase.loading);

    if (_selection.isEmpty) {
      _setPhase(ClipPhase.empty);
      return;
    }

    if (announceStart) {
      services.analytics.lookupStarted(
        kind: _selection.kind ?? LookupKind.word,
        source: source,
      );
    }

    _entitlement = await services.entitlements.current();
    if (_disposed) return;

    if (!services.connectivity.isOnline) {
      await _serveFromHistoryOrOffline();
      return;
    }

    await _requestLookup();
  }

  /// Reuses the open view for a new selection
  /// (`docs/Scenova/user-flow.md` → "Alternate Path E").
  Future<void> submit(CaptureSelection selection) async {
    if (selection.isEmpty) {
      _selection = selection;
      await load();
      return;
    }
    _selection = selection;
    await load();
  }

  Future<void> retry() => load(announceStart: false);

  /// The reader picked the sense that fits.
  void chooseSense(Sense sense) {
    _chosenSense = sense;
    _setPhase(ClipPhase.playing);
    _autoplayOrHold();
    unawaited(_saveToHistory());
  }

  void togglePlay() {
    if (_phase != ClipPhase.playing) return;
    _playing = !_playing;
    if (_playing) _trackClipPlayed();
    notifyListeners();
  }

  void onPlaybackCompleted() {
    if (!_playing) return;
    _playing = false;
    notifyListeners();
  }

  void markFeedback(FeedbackMark mark) {
    _feedback = mark;
    services.analytics.clipFeedbackGiven(
      rating: mark == FeedbackMark.helpful
          ? AnalyticsRating.helpful
          : AnalyticsRating.notHelpful,
      clipSource: _clipSource,
    );
    notifyListeners();
  }

  void dismissGeneratingNotice() {
    _noticeShown = false;
    notifyListeners();
  }

  /// The reader asked to be told when the clip is ready.
  void requestNotification() {
    _willNotify = true;
    _noticeShown = false;
    notifyListeners();
  }

  Future<void> _requestLookup() async {
    try {
      final request = LookupRequest(
        selection: _selection.text,
        clientLookupId: _clientLookupId(),
        platform: LookupPlatform.current(),
        locale: services.locale,
        consentModelProcessing: services.settings.consentModelProcessing,
      );
      final result = await services.lookupApi.createLookup(request);
      if (_disposed) return;
      _applyResult(result);
    } on LookupApiException catch (error) {
      if (_disposed) return;
      if (error.isOffline) {
        await _serveFromHistoryOrOffline();
        return;
      }
      _errorMessage = error.message;
      _setPhase(ClipPhase.error);
    }
  }

  void _applyResult(LookupResult result) {
    _result = result;

    // A served lookup whose sense carries a library entry is a library hit; the
    // entry id is the join key the report uses.
    if (result.status == LookupStatus.served) {
      final entryId = result.playableSenses.isEmpty
          ? null
          : result.playableSenses.first.entryId;
      if (entryId != null) services.analytics.lookupServed(entryId: entryId);
    }

    // With the allowance spent the word and phrase still show; no clip is
    // generated until the allowance is restored.
    if (_entitlement.exhausted) {
      services.analytics.allowanceExhausted(plan: _entitlement.tier.name);
      _setPhase(ClipPhase.allowanceExhausted);
      return;
    }

    switch (result.status) {
      case LookupStatus.served:
        final playable = result.playableSenses;
        if (playable.length > 1) {
          _setPhase(ClipPhase.senseChoice);
        } else if (playable.length == 1) {
          _chosenSense = playable.first;
          _setPhase(ClipPhase.playing);
          _autoplayOrHold();
          unawaited(_saveToHistory());
        } else {
          _setPhase(ClipPhase.fallback);
        }
      case LookupStatus.generating:
        _setPhase(ClipPhase.generating);
        _startPoll();
      case LookupStatus.fallback:
        _setPhase(ClipPhase.fallback);
      case LookupStatus.denied:
        _setPhase(ClipPhase.denied);
      case LookupStatus.empty:
        _setPhase(ClipPhase.empty);
    }
  }

  void _autoplayOrHold() {
    // Reduce motion holds the clip on a still frame and plays on tap.
    _playing = !services.settings.reduceMotion;
    if (_playing) _trackClipPlayed();
    notifyListeners();
  }

  /// Records that a clip started playing (`EVT-010`). The source distinguishes
  /// a library clip from a generated one, and a device replay from history.
  void _trackClipPlayed() {
    services.analytics.clipPlayed(
      clipSource: _clipSource,
      entryId: (_chosenSense ?? _firstSense)?.entryId,
    );
  }

  /// Where the clip that would play came from.
  ClipSource get _clipSource {
    if (_fromHistory) return ClipSource.saved;
    final entryId = (_chosenSense ?? _firstSense)?.entryId;
    return entryId == null ? ClipSource.generated : ClipSource.library;
  }

  void _startPoll() {
    _generatingPolls = 0;
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final lookupId = _result?.lookupId;
    if (lookupId == null) {
      _cancelPoll();
      return;
    }
    // The wait is measured in poll intervals so it is independent of the wall
    // clock and reproducible in tests.
    _generatingPolls++;
    final elapsed = _pollInterval * _generatingPolls;
    if (elapsed >= _noticeThreshold && !_noticeShown && !_willNotify) {
      _noticeShown = true;
      notifyListeners();
    }
    if (elapsed >= _pollTimeout) {
      _cancelPoll();
      _errorMessage = 'The clip is taking longer than usual.';
      _setPhase(ClipPhase.error);
      return;
    }
    try {
      final result = await services.lookupApi.getLookup(lookupId);
      if (_disposed) return;
      if (result.status != LookupStatus.generating) {
        _cancelPoll();
        _applyResult(result);
      }
    } on LookupApiException catch (error) {
      if (_disposed) return;
      _cancelPoll();
      if (error.isOffline) {
        await _serveFromHistoryOrOffline();
      } else {
        _errorMessage = error.message;
        _setPhase(ClipPhase.error);
      }
    }
  }

  Future<void> _serveFromHistoryOrOffline() async {
    final saved = await _savedClipFor(_selection.text);
    if (_disposed) return;
    if (saved != null) {
      _fromHistory = true;
      _result = _placeholderResult(sense: saved);
      _chosenSense = _result!.senses.first;
      _setPhase(ClipPhase.playing);
      _autoplayOrHold();
      return;
    }
    _setPhase(ClipPhase.offline);
  }

  Future<Sense?> _savedClipFor(String word) async {
    final entries = await services.historyStore.all();
    final match = entries
        .where(
          (entry) =>
              entry.word.toLowerCase() == word.toLowerCase() &&
              entry.clipUrl != null,
        )
        .firstOrNull;
    if (match == null) return null;
    return Sense(
      senseLabel: '1',
      partOfSpeech: '',
      glossPhrase: match.phrase,
      clip: Clip(
        url: match.clipUrl!,
        durationSeconds: AppConfig.clipDurationFallback.inSeconds.toDouble(),
        resolution: '360p',
        hasAudio: match.hasAudio,
      ),
    );
  }

  Future<void> _saveToHistory() async {
    final result = _result;
    if (result == null) return;
    // Only a lookup that resolved is saved; a fallback or a denied lookup has
    // no clip to replay.
    if (result.status != LookupStatus.served) return;
    await services.historyStore.save(
      historyEntryFrom(result, savedAt: DateTime.now(), sense: _chosenSense),
    );
  }

  /// A result that carries the word and phrase but no clip, used for the
  /// allowance-exhausted and offline-with-saved-clip cases.
  LookupResult _placeholderResult({Sense? sense}) {
    return LookupResult(
      lookupId: 'local-${_selection.text}',
      kind: _selection.kind ?? LookupKind.word,
      rawSelection: _selection.text,
      normalisedLemma: _selection.text,
      status: sense == null ? LookupStatus.fallback : LookupStatus.served,
      senses: <Sense>[
        sense ??
            Sense(
              senseLabel: '1',
              partOfSpeech: '',
              glossPhrase: '',
              entryId: null,
            ),
      ],
      notice: null,
      correlationId: 'local',
    );
  }

  String _clientLookupId() =>
      '${_selection.text.hashCode.toRadixString(16)}-${DateTime.now().microsecondsSinceEpoch}';

  void _setPhase(ClipPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _cancelPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _generatingPolls = 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPoll();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
