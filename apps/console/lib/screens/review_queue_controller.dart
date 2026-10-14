import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/review_queue.dart';
import '../services/review_api.dart';

/// The queue's load state (`docs/Scenova/screens/09-review-queue.md` →
/// "States").
enum ReviewQueueStatus {
  /// The queue is loading: a skeleton table.
  loading,

  /// The queue loaded: the filter bar and the table.
  loaded,

  /// The queue could not be loaded: the shared Error State with a retry.
  error,

  /// The operator is authenticated but may not review: access is refused.
  refused,
}

/// Owns the review queue's data, its filter, and its page.
///
/// One controller drives the table, the filter bar, the pagination, and the
/// sidebar's open count, so they never disagree about which slice of the queue
/// is on screen. A session that ends mid-request is reported to
/// [onSessionExpired] so the console can redirect to sign-in; a refused role is
/// kept as its own state, since retrying will not change it.
class ReviewQueueController extends ChangeNotifier {
  ReviewQueueController({required this.api, required this.onSessionExpired});

  final ReviewApi api;

  /// Called when the service reports no operator session, so the console
  /// redirects to sign-in (`C-014`, 401).
  final VoidCallback onSessionExpired;

  ReviewQueueStatus _status = ReviewQueueStatus.loading;
  List<QueueItem> _items = const <QueueItem>[];
  int _openCount = 0;
  int _page = 1;
  int _pageCount = 1;
  ReviewReason? _reason;
  ReviewState? _state;
  String _word = '';
  ReviewApiException? _failure;
  bool _loadedOnce = false;
  bool _refreshing = false;
  int _requestGeneration = 0;
  bool _disposed = false;

  ReviewQueueStatus get status => _status;
  List<QueueItem> get items => _items;
  int get openCount => _openCount;
  int get page => _page;
  int get pageCount => _pageCount;
  ReviewReason? get reasonFilter => _reason;
  ReviewState? get stateFilter => _state;
  String get wordFilter => _word;
  ReviewApiException? get failure => _failure;

  /// Whether a request is in flight while an earlier page is still shown, so
  /// the table can dim rather than collapse into a skeleton.
  bool get isRefreshing => _refreshing;

  /// Whether the current slice is empty because a filter matched nothing,
  /// rather than because the whole queue is empty
  /// (`docs/Scenova/screens/09-review-queue.md` → Edge Cases).
  bool get hasActiveFilters =>
      _reason != null || _state != null || _word.trim().isNotEmpty;

  /// Loads the current filter and page.
  Future<void> load() async {
    final generation = ++_requestGeneration;
    // A refresh over a page that is already shown keeps the table and dims it;
    // a first load, or a retry after a failure, shows the table's skeleton so
    // the attempt is visible.
    if (_loadedOnce && _status == ReviewQueueStatus.loaded) {
      _refreshing = true;
    } else {
      _status = ReviewQueueStatus.loading;
    }
    _notify();

    try {
      final page = await api.queue(
        reason: _reason,
        state: _state,
        word: _word.trim().isEmpty ? null : _word.trim(),
        page: _page,
      );
      if (generation != _requestGeneration || _disposed) return;
      _items = page.items;
      _openCount = page.openCount;
      _page = page.page;
      _pageCount = page.pageCount;
      _status = ReviewQueueStatus.loaded;
      _failure = null;
      _loadedOnce = true;
    } on ReviewApiException catch (error) {
      if (generation != _requestGeneration || _disposed) return;
      if (error.isUnauthenticated) {
        // The session ended while the queue was open; the console redirects to
        // sign-in rather than showing a retry.
        onSessionExpired();
        return;
      }
      _failure = error;
      _status = error.isForbidden
          ? ReviewQueueStatus.refused
          : ReviewQueueStatus.error;
      _loadedOnce = true;
    } finally {
      if (generation == _requestGeneration && !_disposed) {
        _refreshing = false;
        _notify();
      }
    }
  }

  /// Applies the reason filter and reloads from the first page.
  void setReason(ReviewReason? value) {
    if (value == _reason) return;
    _reason = value;
    _reloadFromFirstPage();
  }

  /// Applies the state filter and reloads from the first page.
  void setState(ReviewState? value) {
    if (value == _state) return;
    _state = value;
    _reloadFromFirstPage();
  }

  /// Applies the word filter and reloads from the first page.
  void setWord(String value) {
    if (value == _word) return;
    _word = value;
    _reloadFromFirstPage();
  }

  /// Clears every filter and reloads.
  void clearFilters() {
    if (!hasActiveFilters) return;
    _reason = null;
    _state = null;
    _word = '';
    _reloadFromFirstPage();
  }

  /// Moves to [target] when it is inside the queue's pages.
  void goToPage(int target) {
    final clamped = target.clamp(1, _pageCount);
    if (clamped == _page) return;
    _page = clamped;
    unawaited(load());
  }

  /// Re-asks for the current filter and page.
  Future<void> refresh() => load();

  void _reloadFromFirstPage() {
    _page = 1;
    unawaited(load());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
