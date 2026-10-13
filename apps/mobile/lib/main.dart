import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'models/history_entry.dart';
import 'models/lookup.dart';
import 'services/app_services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale
      .toLanguageTag();
  runApp(
    ScenovaApp(
      services: ScenovaServices.development(
        locale: locale,
        history: _seedHistory(),
      ),
    ),
  );
}

/// A couple of lookups so Home's loaded state is visible in development.
/// `--dart-define=SCENOVA_SEED_HISTORY=false` shows the empty state instead.
List<HistoryEntry> _seedHistory() {
  if (!AppConfig.seedHistory) return const <HistoryEntry>[];
  final now = DateTime.now();
  return <HistoryEntry>[
    HistoryEntry(
      id: 'seed-come',
      word: 'come',
      phrase: 'to move towards someone or something',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(minutes: 6)),
      clipUrl: 'mock://clip/library-hit',
    ),
    HistoryEntry(
      id: 'seed-bank',
      word: 'bank',
      phrase: 'a place that keeps money safe',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(hours: 2)),
      clipUrl: 'mock://clip/bank-money',
    ),
  ];
}
