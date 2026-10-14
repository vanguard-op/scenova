import 'package:flutter/material.dart';

import '../app_router.dart';
import '../models/entitlement.dart';
import '../models/history_entry.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/allowance_indicator.dart';
import '../widgets/app_icons.dart';
import '../widgets/brand_mark.dart';
import '../widgets/enable_action_guide.dart';
import '../widgets/offline_banner.dart';
import '../widgets/scenova_button.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';

/// Where the word entry, the allowance, and recent lookups are.
enum _HomeStatus { loading, loaded, empty, error }

/// Screen 2: Home (`docs/Scenova/screens/02-home.md`).
///
/// The reader's starting point when they open Scenova directly. The entry field
/// is the visual focus, with recent lookups below it. Every state from the
/// screen spec is covered: loading, empty, loaded, and offline.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.router});

  final AppRouter router;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _entry = TextEditingController();
  final FocusNode _entryFocus = FocusNode();

  _HomeStatus _status = _HomeStatus.loading;
  List<HistoryEntry> _recent = const <HistoryEntry>[];
  Entitlement _entitlement = Entitlement.unmeteredGuest;
  String? _validationMessage;
  bool _online = true;
  ScenovaServices? _services;

  ScenovaServices get _scope => _services!;

  @override
  void initState() {
    super.initState();
    widget.router.notice.addListener(_onNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entryFocus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    // The services are read here rather than in initState so the inherited
    // scope is safe to depend on.
    final services = ScenovaScope.of(context);
    _services = services;
    _online = services.connectivity.isOnline;
    services.connectivity.changes.listen(_onConnectivity);
    services.settings.addListener(_onSettingsChanged);
    _load();
  }

  @override
  void dispose() {
    _entry.dispose();
    _entryFocus.dispose();
    widget.router.notice.removeListener(_onNotice);
    _services?.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onConnectivity(bool online) {
    if (!mounted) return;
    setState(() => _online = online);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onNotice() {
    if (!mounted) return;
    final notice = widget.router.notice.value;
    if (notice == null) return;
    setState(() => _validationMessage = notice.message);
    widget.router.clearNotice();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _status = _HomeStatus.loading);
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _scope.historyStore.recent(limit: 5),
        _scope.entitlements.current(),
      ]);
      if (!mounted) return;
      final recent = results[0] as List<HistoryEntry>;
      setState(() {
        _recent = recent;
        _entitlement = results[1] as Entitlement;
        _status = recent.isEmpty ? _HomeStatus.empty : _HomeStatus.loaded;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _status = _HomeStatus.error);
    }
  }

  void _submit() {
    final selection = CaptureSelection.parse(_entry.text);
    if (selection.isEmpty) {
      // No lookup starts on an empty or whitespace-only selection.
      setState(() => _validationMessage = 'Type or paste a word to look up.');
      return;
    }
    if (selection.overLimit) {
      // A selection over the phrase limit is not looked up; the reader is
      // asked to narrow it in place rather than losing their edit
      // (`FEAT-007`).
      setState(() => _validationMessage = selection.notice);
      return;
    }
    setState(() => _validationMessage = null);
    widget.router.openSelection(selection);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            BrandMark(size: tokens.sizing.iconMd),
            SizedBox(width: tokens.spacing.sm),
            // The mark takes its width from its delivered aspect ratio, so the
            // wordmark flexes rather than the row overflowing on a narrow phone.
            Flexible(
              child: Text(
                'Scenova',
                style: styles.h2.copyWith(color: colors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          ScenovaIconButton(
            icon: AppIcons.history,
            tooltip: 'History',
            onPressed: widget.router.openHistory,
          ),
          ScenovaIconButton(
            icon: AppIcons.settings,
            tooltip: 'Preferences',
            onPressed: widget.router.openPreferences,
          ),
          ScenovaIconButton(
            icon: AppIcons.account,
            tooltip: 'Account',
            onPressed: widget.router.openAccount,
          ),
          SizedBox(width: tokens.spacing.xs),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.lg,
            vertical: tokens.spacing.md,
          ),
          children: <Widget>[
            if (!_online) ...<Widget>[
              const OfflineBanner(),
              SizedBox(height: tokens.spacing.md),
            ],
            if (!_scope.settings.actionEnabled) ...<Widget>[
              EnableActionGuide(
                compact: true,
                onOpen: widget.router.openPreferences,
              ),
              SizedBox(height: tokens.spacing.md),
            ],
            AllowanceIndicator(entitlement: _entitlement),
            SizedBox(height: tokens.spacing.md),
            TextField(
              controller: _entry,
              focusNode: _entryFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_validationMessage != null) {
                  setState(() => _validationMessage = null);
                }
              },
              decoration: InputDecoration(
                hintText: 'Type or paste a word',
                prefixIcon: AppIconView(
                  icon: AppIcons.search,
                  size: tokens.sizing.iconMd,
                  color: colors.iconDefault,
                ),
                errorText: _validationMessage,
              ),
            ),
            SizedBox(height: tokens.spacing.md),
            ScenovaButton(
              label: 'Look up',
              onPressed: _submit,
              expanded: true,
              variant: ScenovaButtonVariant.primary,
            ),
            SizedBox(height: tokens.spacing.xl),
            _body(context),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final colors = ScenovaColors.of(context);

    switch (_status) {
      case _HomeStatus.loading:
        return const SkeletonList(rows: 4);
      case _HomeStatus.error:
        return ErrorState(
          headline: 'Your recent lookups did not load',
          body: 'Check your connection and try again.',
          onRetry: _load,
        );
      case _HomeStatus.empty:
        return EmptyState(
          icon: AppIcons.seeIt,
          headline: 'Look up a word while you read',
          body:
              'Select a word in a reading app and open Scenova from the menu. '
              'You can also type or paste a word above.',
          actionLabel: 'How to enable it',
          onAction: widget.router.openPreferences,
        );
      case _HomeStatus.loaded:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Recent',
              style: styles.h2.copyWith(color: colors.textPrimary),
            ),
            SizedBox(height: tokens.spacing.sm),
            for (final entry in _recent)
              _RecentRow(entry: entry, router: widget.router),
          ],
        );
    }
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry, required this.router});

  final HistoryEntry entry;
  final AppRouter router;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: tokens.spacing.sm,
      onTap: () => router.openSelection(CaptureSelection.parse(entry.word)),
      title: Text(
        entry.word,
        style: styles.body.copyWith(color: colors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: entry.phrase.isEmpty
          ? null
          : Text(
              entry.phrase,
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }
}
