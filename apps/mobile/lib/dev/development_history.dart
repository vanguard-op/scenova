import '../models/history_entry.dart';
import '../models/lookup.dart';
import '../services/history_store.dart';

/// Sample lookups for the development surfaces that need a loaded history.
///
/// The preview gallery draws its loaded frames from here, and a development run
/// can opt into the same data with `--dart-define=SCENOVA_SEED_HISTORY=true` so
/// the loaded state is visible on a device. It is development-only: the app
/// holds it in memory for that run and never writes it to the store the reader's
/// own history lives in, which is the reader's alone (`FEAT-009`).
///
/// The entries name no clip source, so opening one shows the shared still-frame
/// stand-in rather than a source that cannot play.
List<HistoryEntry> sampleHistory() {
  final now = DateTime.now();
  return <HistoryEntry>[
    HistoryEntry(
      id: 'seed-come',
      word: 'come',
      phrase: 'to move towards someone or something',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(minutes: 6)),
    ),
    HistoryEntry(
      id: 'seed-bank',
      word: 'bank',
      phrase: 'a place that keeps money safe',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(hours: 2)),
    ),
  ];
}

/// The history store a launch runs against.
///
/// A run that opts into the sample data holds it in memory for that run, so the
/// samples never reach the store the reader's own history lives in and never
/// persist; every other run reads and writes the reader's own store, which
/// starts empty and outlives the launch (`FEAT-009`). [deviceStore] is the
/// reader's own store, supplied by a caller that already holds one; a launch
/// that names none builds the durable device store.
HistoryStore launchHistoryStore({
  required bool seed,
  HistoryStore? deviceStore,
}) {
  if (seed) return InMemoryHistoryStore(seed: sampleHistory());
  return deviceStore ?? SharedPreferencesHistoryStore();
}
