import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../app_router.dart';
import '../models/history_entry.dart';
import '../services/app_services.dart';
import '../services/history_store.dart';
import '../services/poster_frame_store.dart';

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
      await _pruneDeviceMedia(entries);
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

  /// Drops the clips and poster frames of entries the device no longer keeps.
  ///
  /// History keeps only the most recent lookups, so an entry that drops off
  /// must not leave its clip or frame behind. A sweep that fails costs the
  /// reader nothing, so it never surfaces as an error.
  Future<void> _pruneDeviceMedia(List<HistoryEntry> entries) async {
    final clipKeys = entries
        .map((entry) => entry.clipLocalKey)
        .whereType<String>();
    final posterKeys = entries
        .map((entry) => entry.posterLocalKey)
        .whereType<String>();
    try {
      await _scope.clips.pruneTo(clipKeys);
    } on Object {
      // The clips stay until the next sweep.
    }
    try {
      await _scope.posterFrames.pruneTo(posterKeys);
    } on Object {
      // The frames stay until the next sweep.
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
    await _removeDeviceMedia(entry);
    if (!mounted) return;
    setState(() {
      _deletingId = null;
      _entries = _entries
          .where((existing) => existing.id != entry.id)
          .toList(growable: false);
      if (_entries.isEmpty) _status = _HistoryStatus.empty;
    });
  }

  /// Deletes the clip and frame kept for [entry], best-effort.
  ///
  /// The entry is already gone from the list, so media the device refuses to
  /// delete is swept on the next load rather than surfacing as an error
  /// (`FEAT-009` → "the item and its clip are deleted from the device").
  Future<void> _removeDeviceMedia(HistoryEntry entry) async {
    final clipKey = entry.clipLocalKey;
    if (clipKey != null) {
      try {
        await _scope.clips.remove(clipKey);
      } on Object {
        // The clip is swept when history is next loaded.
      }
    }
    final posterKey = entry.posterLocalKey;
    if (posterKey == null) return;
    try {
      await _scope.posterFrames.remove(posterKey);
    } on Object {
      // The frame is swept when history is next loaded.
    }
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
      await _scope.clips.clear();
      await _scope.posterFrames.clear();
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
              posters: _scope.posterFrames,
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
    required this.posters,
    required this.deleting,
    required this.onOpen,
    required this.onRemove,
  });

  final HistoryEntry entry;

  /// The device's poster frames, which the thumbnail draws from.
  final PosterFrameStore posters;

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
                _Thumbnail(entry: entry, posters: posters),
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

/// The saved clip's poster frame, or the shared still-frame stand-in.
///
/// The frame is derived from the clip when the lookup is saved and kept on the
/// device under the entry's key (`FEAT-009`), so the row shows the lookup at a
/// glance without opening the clip. When the entry has no frame — no clip, or a
/// frame that could not be derived — the row shows the same still-frame stand-in
/// the shared Clip Player uses (`docs/Scenova/screens/06-history.md` → Edge
/// Cases).
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.entry, required this.posters});

  final HistoryEntry entry;
  final PosterFrameStore posters;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Uint8List? _frame;

  @override
  void initState() {
    super.initState();
    _loadFrame();
  }

  @override
  void didUpdateWidget(_Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry.posterLocalKey != oldWidget.entry.posterLocalKey) {
      _loadFrame();
    }
  }

  Future<void> _loadFrame() async {
    final key = widget.entry.posterLocalKey;
    if (key == null) {
      if (_frame != null) setState(() => _frame = null);
      return;
    }
    final frame = await widget.posters.frame(key);
    if (!mounted) return;
    setState(() => _frame = frame);
  }

  /// What the frame is, for a reader who cannot see it.
  String get _label {
    if (_frame != null) return 'Poster frame for ${widget.entry.word}';
    if (widget.entry.hasClip) return 'Clip for ${widget.entry.word}';
    return 'No clip saved for ${widget.entry.word}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    // The frame is sized from the icon scale, composed to the clip's 16:9.
    final width = tokens.sizing.iconLg * 3;
    final frame = _frame;

    return Semantics(
      image: true,
      label: _label,
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          child: frame == null
              ? ClipStillFrame(
                  markSize: tokens.sizing.iconSm,
                  padding: EdgeInsets.zero,
                )
              : Image.memory(frame, fit: BoxFit.cover),
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
