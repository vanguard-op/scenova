import '../models/history_entry.dart';
import 'clip_store.dart';
import 'history_store.dart';
import 'poster_frame_store.dart';
import 'tier_gates.dart';

/// Fetches a saved lookup's clip and derives its poster frame, keeping both on
/// the device beside the entry (`FEAT-009`).
///
/// A saved lookup keeps the clip itself, not only a reference to it, so it
/// replays with no connection, and it keeps a poster frame so the History row
/// shows it at a glance. Both are fetched and derived the same way whether the
/// entry is a fresh lookup or a clip the reader reported that a regenerated one
/// has replaced.
///
/// The reader's plan gates the clip: Pro keeps it, while the Free tier keeps the
/// word, the phrase, and the poster frame but not the clip, so a Free reader's
/// saved lookup replays only while online
/// (`docs/Scenova/monetization.md` → "Feature Gate Mapping").
class SavedClipKeeper {
  SavedClipKeeper({
    required this.history,
    required this.clips,
    required this.posters,
    required this.gates,
  });

  final HistoryStore history;
  final ClipStore clips;
  final PosterFrameStore posters;
  final TierGates gates;

  /// The source a replay plays for [entry]: the device's own copy when it holds
  /// one, otherwise the entry's source URL, which replays while online.
  Future<String?> sourceFor(HistoryEntry entry) async {
    final key = entry.clipLocalKey;
    if (key != null) {
      final source = await clips.source(key);
      if (source != null) return source;
    }
    return entry.clipUrl;
  }

  /// Fetches [entry]'s clip and keeps it on the device, returning the entry
  /// with its local key set when the clip was kept.
  ///
  /// A clip the device cannot fetch or keep leaves the entry on its source,
  /// which still replays while online, and returns the entry unchanged. A plan
  /// that withholds clip retention — the Free tier, or any plan while the paid
  /// tier is killed — also leaves the entry on its source.
  Future<HistoryEntry> keepClip(HistoryEntry entry) async {
    final clipUrl = entry.clipUrl;
    if (clipUrl == null) return entry;
    if (!await gates.retainsClips()) return entry;
    final key = await clips.save(clipUrl: clipUrl, key: entry.id);
    if (key == null) return entry;
    final kept = entry.copyWith(clipLocalKey: key);
    await history.save(kept);
    return kept;
  }

  /// Derives the poster frame for [entry] and keeps it with the stored entry.
  ///
  /// The kept clip is the source when the device holds one, so the frame
  /// derives from the saved clip rather than reaching for the source again; a
  /// clip the platform cannot read keeps no frame, and the row falls back to the
  /// shared still-frame stand-in.
  Future<void> keepPoster(HistoryEntry entry) async {
    final clipUrl = await sourceFor(entry);
    if (clipUrl == null) return;
    final key = await posters.capture(clipUrl: clipUrl, key: entry.id);
    if (key == null) return;
    await history.save(entry.copyWith(posterLocalKey: key));
  }
}
