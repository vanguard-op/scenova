import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/analytics_event.dart';
import '../models/clip_notice.dart';
import '../models/entitlement.dart';
import '../models/history_entry.dart';
import '../models/lookup.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import '../services/lookup_api.dart';
import '../services/push_registrar.dart';

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

  /// The selection is longer than the phrase limit, so the reader is asked to
  /// narrow it (`FEAT-007`). No lookup starts.
  selectionTooLong,

  /// The in-context view is switched off at runtime (`enable_clip_view`), so
  /// the reader sees the selected word and its phrase with no clip.
  wordAndPhrase,
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
    HistoryEntry? savedEntry,
    Duration? pollInterval,
    Duration? noticeThreshold,
    Duration? pollTimeout,
  }) : _pollInterval = pollInterval ?? AppConfig.lookupPollInterval,
       _noticeThreshold =
           noticeThreshold ?? AppConfig.generatingNoticeThreshold,
       _pollTimeout = pollTimeout ?? AppConfig.lookupPollTimeout {
    _selection = selection;
    _savedEntry = savedEntry;
    // The clip-ready notice is listened for from the moment the view opens, so
    // a notice that arrives while the reader waits reaches this view (`C-008`).
    _noticeSub = services.clipNotices.notices.listen(_onNotice);
  }

  final ScenovaServices services;

  /// Where this lookup entered the app, for `lookup_started`'s `source`.
  final LookupSource source;
  final Duration _pollInterval;
  final Duration _noticeThreshold;
  final Duration _pollTimeout;

  late CaptureSelection _selection;

  /// The saved lookup this view replays, when it was opened from History.
  ///
  /// A saved lookup plays from the device with no lookup and no generation; it
  /// is cleared when a new selection replaces it, so the view stops replaying
  /// and resolves the new selection normally (`docs/Scenova/user-flow.md` →
  /// Flow 3).
  HistoryEntry? _savedEntry;
  LookupResult? _result;
  Sense? _chosenSense;
  ClipPhase _phase = ClipPhase.loading;
  Entitlement _entitlement = Entitlement.unmeteredGuest;
  String? _errorMessage;
  Timer? _pollTimer;
  Timer? _noticeTimer;
  Timer? _timeoutTimer;
  StreamSubscription<ClipNotice>? _noticeSub;
  bool _disposed = false;

  bool _playing = false;
  bool _willNotify = false;
  bool _pastThreshold = false;
  bool _noticeDismissed = false;
  bool _fromHistory = false;

  /// Whether the first load has run. Until it has, a newer selection is left to
  /// the load that mounting triggers rather than starting a second lookup.
  bool _loaded = false;
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

  /// Whether the selection is a short phrase rather than a single word.
  bool get isPhrase => _selection.kind == LookupKind.phrase;

  /// The gloss phrase to show, from the chosen sense or the first sense.
  ///
  /// A phrase is its own gloss — there is no separate meaning to set beneath it
  /// — so it is left out of the header rather than repeated under the clip
  /// (`FEAT-007`).
  String? get phrase {
    final sense = _chosenSense ?? _firstSense;
    final value = sense?.glossPhrase;
    if (value == null || value.isEmpty) return null;
    if (isPhrase && value.toLowerCase() == word.toLowerCase()) return null;
    return value;
  }

  /// The clip that would play.
  Clip? get clip => _chosenSense?.clip ?? _result?.primaryClip;

  /// The note shown with the word and phrase.
  ///
  /// It carries any reader-facing advisory the service sends, including the
  /// best-guess note when the word is outside the sense inventory. The sense
  /// label is a human label and is never read as a signal.
  String? get note => _result?.notice;

  /// Whether the in-context view is shown at all (`enable_clip_view`).
  bool get _clipViewEnabled => services.featureFlags.clipViewEnabled;

  Sense? get _firstSense =>
      (_result?.senses.isEmpty ?? true) ? null : _result!.senses.first;

  /// The first sense still waiting on its clip, so a notice settles the sense
  /// that has none rather than one that already plays.
  Sense? get _firstSenseWithoutClip {
    final senses = _result?.senses ?? const <Sense>[];
    for (final sense in senses) {
      if (!sense.hasClip) return sense;
    }
    return null;
  }

  /// Whether the notice SnackBar should be raised for this change.
  ///
  /// It is raised once: [markGeneratingNoticeShown] records that it has been
  /// shown, and taking the notice with [notifyWhenReady] settles it.
  bool get shouldShowGeneratingNotice =>
      _pastThreshold &&
      _phase == ClipPhase.generating &&
      !_willNotify &&
      !_noticeDismissed;

  /// Whether generation has run past the wait threshold.
  ///
  /// The clip surface settles on a still message while this holds; the reader
  /// is no longer shown a spinner once the wait is long enough to be worth
  /// explaining.
  bool get pastWaitThreshold =>
      _pastThreshold && _phase == ClipPhase.generating;

  /// Loads the selection. Called on mount and on reuse.
  ///
  /// [announceStart] emits `lookup_started`; a retry of the same lookup passes
  /// false so the funnel counts the lookup once.
  Future<void> load({bool announceStart = true}) async {
    _loaded = true;
    _cancelPoll();
    _playing = false;
    _feedback = null;
    _willNotify = false;
    _pastThreshold = false;
    _noticeDismissed = false;
    _fromHistory = false;
    _errorMessage = null;
    _chosenSense = null;
    _result = null;
    _setPhase(ClipPhase.loading);

    if (_selection.isEmpty) {
      _setPhase(ClipPhase.empty);
      return;
    }

    // A selection over the phrase limit starts no lookup; the reader is asked
    // to narrow it instead (`FEAT-007`).
    if (_selection.overLimit) {
      _setPhase(ClipPhase.selectionTooLong);
      return;
    }

    // A lookup opened from History replays the clip the device already holds;
    // it starts no lookup and no generation.
    final saved = _savedEntry;
    if (saved != null) {
      _serveSavedEntry(saved);
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

    // A phrase clip is kept only on the device and never enters the shared
    // library, so a phrase this device has already looked up is served from
    // its own history without a new generation (`FEAT-007`). With the clip view
    // switched off there is no clip to serve, so the phrase resolves normally.
    if (_selection.kind == LookupKind.phrase && _clipViewEnabled) {
      final saved = await _savedClipFor(_selection);
      if (_disposed) return;
      if (saved != null) {
        _serveSavedClip(saved);
        return;
      }
    }

    if (!services.connectivity.isOnline) {
      await _serveFromHistoryOrOffline();
      return;
    }

    await _requestLookup();
  }

  /// Reuses the open view for a new selection
  /// (`docs/Scenova/user-flow.md` → "Alternate Path E").
  ///
  /// A selection this view already carries is the reader invoking the entry
  /// point twice in a row — the Android action delivered again while the card
  /// is up (`FEAT-001`, Edge Cases). The existing lookup is reused rather than
  /// started again, so one received word reports one lookup and starts one
  /// generation. A different selection updates the view in place.
  Future<void> submit(CaptureSelection selection) async {
    if (_isShowing(selection)) return;
    _selection = selection;
    // The view has moved on from the saved lookup it opened on, so the new
    // selection resolves normally rather than replaying the old entry.
    _savedEntry = null;
    // A selection that arrives before the first frame is loaded by the mount,
    // which reads [_selection]; loading here as well would start the same
    // lookup twice.
    if (!_loaded) return;
    await load();
  }

  /// Whether this view is already showing [selection].
  ///
  /// The normalised text and the kind are compared, so a word delivered again
  /// — with or without the punctuation the entry gate trims — reads as the same
  /// selection.
  bool _isShowing(CaptureSelection other) =>
      other.text == _selection.text && other.kind == _selection.kind;

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

  /// Records that the generating notice has been raised, so it is shown once.
  void markGeneratingNoticeShown() => _noticeDismissed = true;

  /// The reader asked to be told when the clip is ready.
  ///
  /// This registers the device with the notice service against the lookup the
  /// reader is waiting on (`C-008`) and returns what came of it. The reader's
  /// choice stands either way; a registration held for the connection is retried
  /// when it returns.
  Future<PushNoticeResult> notifyWhenReady() async {
    _willNotify = true;
    _noticeDismissed = true;
    notifyListeners();
    final lookupId = _result?.lookupId;
    // Only a lookup the service knows about can be watched; a result built
    // from the device's own store has none.
    if (lookupId == null) return PushNoticeResult.notRegistered;
    final outcome = await services.pushRegistrar.requestClipReadyNotice(
      lookupId: lookupId,
    );
    if (_disposed) return outcome;
    // A phrase has no delivery path but the notice, so a reader who cannot be
    // reached is shown the clip as unavailable with a retry rather than left
    // waiting on one that will never come (`FEAT-007`, Edge Cases).
    if (isPhrase &&
        (outcome == PushNoticeResult.notificationsDenied ||
            outcome == PushNoticeResult.notificationsPermanentlyDenied)) {
      _cancelPoll();
      _setPhase(ClipPhase.fallback);
    }
    return outcome;
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

    // A notice may have reached the device before the lookup did — the reader
    // opened it from their notification, say. It is taken up rather than
    // dropped, so the clip is played and kept (`C-008`).
    final waiting = services.clipNotices.takeFor(result.lookupId);
    if (waiting != null && _clipViewEnabled) {
      _applyNotice(waiting);
      return;
    }

    // With the in-context view switched off (`enable_clip_view`) the reader
    // still gets the word and its phrase, but no clip is played and no
    // generation is polled for. A served lookup is still saved, so the word and
    // phrase reach the reader's history.
    if (!_clipViewEnabled) {
      if (result.status == LookupStatus.served) unawaited(_saveToHistory());
      _setPhase(ClipPhase.wordAndPhrase);
      return;
    }

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
        // A phrase clip reaches the device only by the clip-ready notice, so
        // the device is registered for it as soon as the phrase is generating
        // rather than waiting for the offer, which a clip that finishes quickly
        // would outrun (`FEAT-007`).
        if (result.kind == LookupKind.phrase) {
          unawaited(_watchForPhraseClip(result.lookupId));
        }
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
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
    // The wait threshold and the timeout are wall-clock deadlines, not
    // multiples of the poll interval: the reader is told at ten seconds, not at
    // the first poll after it, and the lookup stops when its own deadline
    // passes rather than when a poll happens to notice.
    _noticeTimer = Timer(_noticeThreshold, _markPastThreshold);
    _timeoutTimer = Timer(_pollTimeout, _timeout);
  }

  /// The wait passed without the clip being ready, so the reader is told it is
  /// still being made.
  void _markPastThreshold() {
    if (_disposed || _phase != ClipPhase.generating || _pastThreshold) return;
    _pastThreshold = true;
    notifyListeners();
  }

  /// The lookup has been generating for longer than the client will wait.
  void _timeout() {
    if (_disposed || _phase != ClipPhase.generating) return;
    _cancelPoll();
    // A phrase clip has no delivery path but the notice, so a wait that has run
    // out leaves the phrase with the clip unavailable and a retry rather than a
    // lookup failure (`FEAT-007`, Edge Cases).
    if (isPhrase) {
      _setPhase(ClipPhase.fallback);
      return;
    }
    _errorMessage = 'The clip is taking longer than usual.';
    _setPhase(ClipPhase.error);
  }

  /// A clip-ready notice reached the device (`C-008`).
  void _onNotice(ClipNotice notice) {
    if (_disposed) return;
    if (_result?.lookupId != notice.lookupId) return;
    services.clipNotices.takeFor(notice.lookupId);
    // With the in-context view switched off no clip is played, so the notice
    // is consumed and nothing else happens.
    if (!_clipViewEnabled) return;
    _applyNotice(notice);
  }

  /// Applies the clip the notice carried: it plays, and it is saved to the
  /// device's own history (`FEAT-007`, `FEAT-008`).
  ///
  /// The clip arrives outside the lookup read path — for a phrase it is the
  /// only way it ever arrives — so the lookup is settled here rather than by a
  /// poll.
  void _applyNotice(ClipNotice notice) {
    final result = _result;
    if (result == null) return;
    _cancelPoll();
    final current = _chosenSense ?? _firstSenseWithoutClip ?? _firstSense;
    final sense = Sense(
      senseLabel: current?.senseLabel ?? '1',
      partOfSpeech: current?.partOfSpeech ?? '',
      glossPhrase: current?.glossPhrase ?? result.rawSelection,
      entryId: current?.entryId,
      clip: notice.clip,
    );
    _result = _withSense(result, sense);
    _chosenSense = sense;
    _fromHistory = false;
    _pastThreshold = false;
    _noticeDismissed = true;
    _setPhase(ClipPhase.playing);
    _autoplayOrHold();
    unawaited(_saveToHistory());
  }

  /// The lookup with [sense] in place of the sense it settles, so the clip the
  /// notice carried is what the view plays.
  LookupResult _withSense(LookupResult result, Sense sense) {
    final senses = List<Sense>.of(result.senses);
    final index = senses.indexWhere(
      (existing) =>
          existing.senseLabel == sense.senseLabel &&
          existing.partOfSpeech == sense.partOfSpeech,
    );
    if (index >= 0) {
      senses[index] = sense;
    } else {
      senses.add(sense);
    }
    return LookupResult(
      lookupId: result.lookupId,
      kind: result.kind,
      rawSelection: result.rawSelection,
      normalisedLemma: result.normalisedLemma,
      status: result.status,
      senses: senses,
      notice: result.notice,
      correlationId: result.correlationId,
    );
  }

  /// Registers the device for a phrase's clip-ready notice without raising the
  /// notification prompt.
  ///
  /// A phrase clip is never served on the lookup read path, so the notice is
  /// the only way it reaches the device; registering as the phrase starts
  /// generating means a clip that finishes quickly is still delivered. The
  /// reader who has not answered the prompt is left for the notify offer, where
  /// their own intent is behind it; a reader who refused it for good can never
  /// be reached, so the phrase settles on the clip being unavailable
  /// (`FEAT-007`, Edge Cases).
  Future<void> _watchForPhraseClip(String lookupId) async {
    final outcome = await services.pushRegistrar.requestClipReadyNotice(
      lookupId: lookupId,
      prompt: false,
    );
    if (_disposed) return;
    if (outcome == PushNoticeResult.notificationsPermanentlyDenied) {
      _cancelPoll();
      _setPhase(ClipPhase.fallback);
    }
  }

  Future<void> _poll() async {
    final lookupId = _result?.lookupId;
    if (lookupId == null) {
      _cancelPoll();
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
    if (_clipViewEnabled) {
      final saved = await _savedClipFor(_selection);
      if (_disposed) return;
      if (saved != null) {
        _serveSavedClip(saved);
        return;
      }
    }
    _setPhase(ClipPhase.offline);
  }

  /// Plays [sense], which came from the device's own history rather than a
  /// fresh lookup, and records it as a saved-clip replay.
  void _serveSavedClip(Sense sense) {
    _fromHistory = true;
    _result = _placeholderResult(sense: sense);
    _chosenSense = _result!.senses.first;
    _setPhase(ClipPhase.playing);
    _autoplayOrHold();
  }

  /// Shows the saved lookup the reader chose in History.
  ///
  /// The word and its phrase come from the device, and the clip the device holds
  /// plays without a lookup — so a saved lookup replays with no connection
  /// (`FEAT-009`). A saved lookup whose clip the device no longer holds shows
  /// the word and phrase with the clip unavailable, which is the fallback state.
  void _serveSavedEntry(HistoryEntry entry) {
    _fromHistory = true;
    final url = entry.clipUrl;
    final sense = Sense(
      senseLabel: '1',
      partOfSpeech: '',
      glossPhrase: entry.phrase,
      clip: url == null
          ? null
          : Clip(
              url: url,
              durationSeconds: AppConfig.clipDurationFallback.inSeconds
                  .toDouble(),
              resolution: '360p',
              hasAudio: entry.hasAudio,
            ),
    );
    _result = LookupResult(
      lookupId: entry.id,
      kind: entry.kind,
      rawSelection: entry.word,
      normalisedLemma: entry.word,
      status: url == null ? LookupStatus.fallback : LookupStatus.served,
      senses: <Sense>[sense],
      notice: null,
      correlationId: 'local',
    );
    _chosenSense = sense;
    _setPhase(url == null ? ClipPhase.fallback : ClipPhase.playing);
    if (url != null) _autoplayOrHold();
  }

  /// The clip saved for [selection] on this device, or null.
  ///
  /// Matching on the selection's kind and text keeps a phrase served only by
  /// its own phrase entry; a word and a phrase that share text stay separate.
  Future<Sense?> _savedClipFor(CaptureSelection selection) async {
    final entries = await services.historyStore.all();
    final match = entries
        .where(
          (entry) =>
              entry.kind == selection.kind &&
              entry.word.toLowerCase() == selection.text.toLowerCase() &&
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
    final sense = _chosenSense ?? _firstSense;
    // A lookup that resolved is saved; a fallback or a denied lookup has no
    // clip to replay. A clip the notice carried is saved too: a phrase lookup
    // never resolves to served, and its clip is the reader's to keep
    // (`FEAT-007`).
    if (result.status != LookupStatus.served && (sense?.clip == null)) return;
    await services.historyStore.save(
      historyEntryFrom(result, savedAt: DateTime.now(), sense: sense),
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
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPoll();
    unawaited(_noticeSub?.cancel());
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
