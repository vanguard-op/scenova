import 'dart:async';

import 'package:flutter/material.dart';

import '../app_router.dart';
import '../models/history_entry.dart';
import '../services/app_services.dart';
import '../services/history_store.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/brand_mark.dart';
import '../widgets/offline_banner.dart';
import '../widgets/scenova_button.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';

/// What the history list is doing.
enum _HistoryStatus { loading, loaded, empty, error }

/// Screen 6: History (`docs/Scenova/screens/06-history.md`).
///
/// Browses and replays the reader's saved lookups from the device, including
/// with no connection. The list is newest first, narrows as the reader types in
/// the search field, and each row opens the Clip View on the saved clip or
/// removes the entry after a confirmation.
///
/// Every state from the screen spec is covered: loading, loaded, empty, offline,
/// and deleting.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.router});

  final AppRouter router;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _search = TextEditingController();

  _HistoryStatus _status = _HistoryStatus.loading;
  List<HistoryEntry> _entries = const <HistoryEntry>[];
  String _query = '';

  /// The entry being removed, so its row shows a spinner until it is gone.
  String? _deletingId;
  bool _online = true;
  bool _storageFull = false;
  ScenovaServices? _services;
  StreamSubscription<bool>? _connectivity;

  ScenovaServices get _scope => _services!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    // The services are read here rather than in initState so the inherited
    // scope is safe to depend on.
    final services = ScenovaScope.of(context);
    _services = services;
    _online = services.connectivity.isOnline;
    _connectivity = services.connectivity.changes.listen(_onConnectivity);
    _load();
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onConnectivity(bool online) {
    if (!mounted) return;
    setState(() => _online = online);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _status = _HistoryStatus.loading);
    try {
      final entries = await _scope.historyStore.all();
      final storage = await _scope.historyStore.storageState();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _storageFull = storage == HistoryStorageState.full;
        _status = entries.isEmpty
            ? _HistoryStatus.empty
            : _HistoryStatus.loaded;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _status = _HistoryStatus.error);
    }
  }

  /// The saved lookups the search field admits, newest first.
  List<HistoryEntry> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _entries;
    return _entries
        .where(
          (entry) =>
              entry.word.toLowerCase().contains(query) ||
              entry.phrase.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  void _onQueryChanged(String value) {
    if (value == _query) return;
    setState(() => _query = value);
  }

  Future<void> _confirmRemove(HistoryEntry entry) async {
    final confirmed = await _confirm(
      title: 'Remove this lookup?',
      body:
          'This removes “${entry.word}” and its clip from this device. It '
          'cannot be undone.',
      confirmLabel: 'Remove',
    );
    if (!mounted) return;
    if (confirmed) await _remove(entry);
  }

  Future<void> _remove(HistoryEntry entry) async {
    if (!mounted) return;
    setState(() => _deletingId = entry.id);
    try {
      await _scope.historyStore.remove(entry.id);
    } on Object {
      if (!mounted) return;
      setState(() => _deletingId = null);
      _showMessage('That lookup could not be removed. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _deletingId = null;
      _entries = _entries
          .where((existing) => existing.id != entry.id)
          .toList(growable: false);
      if (_entries.isEmpty) _status = _HistoryStatus.empty;
    });
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await _confirm(
      title: 'Clear all history?',
      body:
          'This removes every saved lookup and its clip from this device. It '
          'cannot be undone.',
      confirmLabel: 'Clear',
    );
    if (!mounted) return;
    if (!confirmed) return;
    try {
      await _scope.historyStore.clear();
    } on Object {
      if (!mounted) return;
      _showMessage('History could not be cleared. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _entries = const <HistoryEntry>[];
      _status = _HistoryStatus.empty;
      _storageFull = false;
    });
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          ScenovaButton(
            label: 'Keep',
            variant: ScenovaButtonVariant.ghost,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          ScenovaButton(
            label: confirmLabel,
            variant: ScenovaButtonVariant.destructive,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            tokens.sizing.inputHeight + tokens.spacing.md,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.lg,
              0,
              tokens.spacing.lg,
              tokens.spacing.md,
            ),
            child: SizedBox(
              height: tokens.sizing.inputHeight,
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                decoration: InputDecoration(
                  hintText: 'Search saved lookups',
                  isDense: true,
                  prefixIcon: AppIconView(
                    icon: AppIcons.search,
                    size: tokens.sizing.iconMd,
                    color: colors.iconDefault,
                  ),
                  prefixIconConstraints: BoxConstraints(
                    minWidth: tokens.sizing.inputHeight,
                    minHeight: tokens.sizing.inputHeight,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            _onQueryChanged('');
                          },
                          tooltip: 'Clear search',
                          icon: AppIconView(
                            icon: AppIcons.close,
                            size: tokens.sizing.iconMd,
                          ),
                        ),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.md,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!_online)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.lg,
                  tokens.spacing.md,
                  tokens.spacing.lg,
                  0,
                ),
                child: OfflineBanner(
                  message: _scope.featureFlags.offlineHistoryEnabled
                      ? null
                      : 'You are offline. Saved clips need a connection to '
                            'play.',
                ),
              ),
            if (_storageFull)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.lg,
                  tokens.spacing.md,
                  tokens.spacing.lg,
                  0,
                ),
                child: _StorageFullBanner(onClear: _confirmClearHistory),
              ),
            Expanded(child: _content(context, styles)),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, ScenovaTextStyles styles) {
    final tokens = ScenovaTokens.of(context);
    final padding = EdgeInsets.symmetric(
      horizontal: tokens.spacing.lg,
      vertical: tokens.spacing.md,
    );

    switch (_status) {
      case _HistoryStatus.loading:
        return ListView(
          padding: padding,
          children: <Widget>[const SkeletonList(rows: 5)],
        );
      case _HistoryStatus.error:
        return ErrorState(
          headline: 'Your history did not load',
          body: 'Check your connection and try again.',
          onRetry: _load,
        );
      case _HistoryStatus.empty:
        return EmptyState(
          icon: AppIcons.history,
          headline: 'No saved lookups yet',
          body:
              'Words you look up while reading are saved here, so you can '
              'replay them any time. Select a word in a reading app and open '
              'Scenova to start.',
        );
      case _HistoryStatus.loaded:
        final visible = _visible;
        if (visible.isEmpty) {
          return EmptyState(
            icon: AppIcons.search,
            headline: 'No matches',
            body: 'No saved lookups match “${_query.trim()}”.',
            actionLabel: 'Clear search',
            onAction: () {
              _search.clear();
              _onQueryChanged('');
            },
          );
        }
        return ListView.separated(
          padding: padding,
          itemCount: visible.length,
          separatorBuilder: (_, _) => SizedBox(height: tokens.spacing.md),
          itemBuilder: (context, index) {
            final entry = visible[index];
            return _HistoryRow(
              entry: entry,
              deleting: entry.id == _deletingId,
              onOpen: () => widget.router.openSavedLookup(entry),
              onRemove: () => _confirmRemove(entry),
            );
          },
        );
    }
  }
}

/// A saved lookup: its clip's frame, the word, its phrase, and Remove.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.deleting,
    required this.onOpen,
    required this.onRemove,
  });

  final HistoryEntry entry;
  final bool deleting;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        // History cards sit on the base surface and carry `shadow-sm`
        // (`docs/Scenova/branding.md` → "Shadows").
        boxShadow: tokens.shadowSm,
      ),
      child: Material(
        color: ScenovaPalette.transparent,
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: deleting ? null : onOpen,
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Thumbnail(entry: entry),
                SizedBox(width: tokens.spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        entry.word,
                        style: styles.h3.copyWith(color: colors.textPrimary),
                        // A long word truncates to two lines.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (entry.phrase.isNotEmpty) ...<Widget>[
                        SizedBox(height: tokens.spacing.xs),
                        Text(
                          entry.phrase,
                          style: styles.bodySmall.copyWith(
                            color: colors.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: tokens.spacing.sm),
                if (deleting)
                  SizedBox.square(
                    dimension: tokens.sizing.buttonHeight,
                    child: Center(
                      child: SizedBox.square(
                        dimension: tokens.sizing.iconMd,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  )
                else
                  ScenovaIconButton(
                    icon: AppIcons.remove,
                    tooltip: 'Remove ${entry.word}',
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A frame of the clip.
///
/// The clip is a video and the device holds its 360p source rather than a
/// still, so the frame is drawn as the shared poster — the brand mark on the
/// primary tint — the same stand-in the Clip Player uses when it has no frame
/// to draw. A saved lookup with no clip shows the muted mark instead.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    // The frame is sized from the icon scale, composed to the clip's 16:9.
    final width = tokens.sizing.iconLg * 3;
    final hasClip = entry.hasClip;

    return Semantics(
      image: true,
      label: hasClip
          ? 'Clip for ${entry.word}'
          : 'No clip saved for ${entry.word}',
      child: Container(
        width: width,
        height: width * 9 / 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hasClip ? colors.primaryTint : colors.surfaceSecondary,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
        ),
        child: BrandMark(
          size: tokens.sizing.iconSm,
          color: hasClip ? colors.primaryDeep : colors.iconDisabled,
        ),
      ),
    );
  }
}

/// The warning shown when the device cannot take another saved lookup, with the
/// way to free room (`FEAT-009` → Edge Cases).
class _StorageFullBanner extends StatelessWidget {
  const _StorageFullBanner({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.md,
          vertical: tokens.spacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.warning.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          border: Border.all(color: colors.warning.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.xs),
              child: AppIconView(
                icon: AppIcons.info,
                size: tokens.sizing.iconSm,
                color: colors.warning.element,
              ),
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'This device is out of room for saved lookups.',
                    style: styles.bodySmall.copyWith(
                      color: colors.warning.text,
                    ),
                  ),
                  SizedBox(height: tokens.spacing.xs),
                  ScenovaButton(
                    label: 'Clear history',
                    variant: ScenovaButtonVariant.ghost,
                    onPressed: onClear,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
