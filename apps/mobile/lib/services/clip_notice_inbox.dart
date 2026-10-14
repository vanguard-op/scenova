import 'dart:async';

import '../models/clip_notice.dart';
import 'clip_notice_source.dart';

/// The app's clip-ready notice intake (`C-008`).
///
/// It listens once, for the whole process, so a notice that arrives while the
/// reader is in the clip view reaches the view waiting on that lookup — whether
/// the app was in the foreground or the reader opened the notice from their
/// notification. A notice that arrives with nothing watching is kept for its
/// lookup, so a view that opens for that lookup still finds the clip instead of
/// losing it. The clip is never retained anywhere but the device
/// (`FEAT-007`).
class ClipNoticeInbox {
  ClipNoticeInbox({required ClipNoticeSource source, int retained = 8})
    : _source = source,
      _retained = retained < 1 ? 1 : retained {
    _subscription = source.notices.listen(_receive);
    unawaited(_adoptOpened());
  }

  final ClipNoticeSource _source;
  final int _retained;
  final StreamController<ClipNotice> _controller =
      StreamController<ClipNotice>.broadcast();
  late final StreamSubscription<ClipNotice> _subscription;

  /// The notice the app was launched from, read once.
  Future<ClipNotice?>? _launch;

  /// Notices that have arrived and are waiting for their lookup, oldest first.
  final Map<String, ClipNotice> _waiting = <String, ClipNotice>{};
  bool _disposed = false;

  /// Every notice that reaches the device, as it arrives.
  Stream<ClipNotice> get notices => _controller.stream;

  /// The notice the app was launched from, when it was opened by one.
  ///
  /// Read once and shared, so a surface that routes the launch notice and the
  /// inbox's own adoption do not ask the platform twice.
  Future<ClipNotice?> openedNotice() => _launch ??= _source.openedFromNotice();

  /// The notice waiting for [lookupId], taken out of the inbox.
  ///
  /// The view that opens for a lookup takes its notice here, so a notice that
  /// arrived while nothing was watching is applied rather than dropped.
  ClipNotice? takeFor(String lookupId) => _waiting.remove(lookupId);

  void _receive(ClipNotice notice) {
    if (_disposed) return;
    // A later notice for the same lookup replaces the earlier one, and the
    // oldest is dropped past the bound: a notice is only useful while the view
    // is waiting, and the list must not grow without limit.
    _waiting
      ..remove(notice.lookupId)
      ..[notice.lookupId] = notice;
    while (_waiting.length > _retained) {
      _waiting.remove(_waiting.keys.first);
    }
    _controller.add(notice);
  }

  /// Takes up the notice the app was launched from, when there was one.
  Future<void> _adoptOpened() async {
    final notice = await openedNotice();
    if (notice != null) _receive(notice);
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    _source.dispose();
    unawaited(_controller.close());
  }
}
