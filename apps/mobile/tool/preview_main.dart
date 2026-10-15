// Development preview gallery.
//
// Renders one screen state per page so the design can be looked at in a browser
// without a reading app: `?frame=<n>`, add `?dark=1` for the dark theme and
// `?device=tablet` for the tablet device class. Built with `flutter build web -t tool/preview_main.dart`; this is tooling, never
// shipped.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scenova/app_router.dart';
import 'package:scenova/models/clip_notice.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/feedback.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/account_controller.dart';
import 'package:scenova/screens/account_screen.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/history_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/screens/paywall_controller.dart';
import 'package:scenova/screens/preferences_controller.dart';
import 'package:scenova/screens/preferences_screen.dart';
import 'package:scenova/services/account_api.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/analytics.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/clip_notice_inbox.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/entitlement_api.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/feedback_api.dart';
import 'package:scenova/services/feedback_outbox.dart';
import 'package:scenova/services/feedback_store.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/identity.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/services/purchase_service.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_registrar.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/report_api.dart';
import 'package:scenova/services/report_outbox.dart';
import 'package:scenova/services/report_store.dart';
import 'package:scenova/services/reported_clip_store.dart';
import 'package:scenova/services/reported_clip_watch.dart';
import 'package:scenova/services/saved_clip_keeper.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/widgets/clear_history_dialog.dart';
import 'package:scenova/widgets/paywall_sheet.dart';
import 'package:scenova/widgets/report_sheet.dart';
import 'package:scenova_design/scenova_design.dart';

void main() => runApp(const PreviewApp());

class PreviewApp extends StatelessWidget {
  const PreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final frames = _frames();
    final params = Uri.base.queryParameters;
    final raw = params['frame'];
    final index = raw == null ? null : int.tryParse(raw);
    final theme = AppTheme.build(
      brightness: params['dark'] == '1' ? Brightness.dark : Brightness.light,
      deviceClass: params['device'] == 'tablet'
          ? DeviceClass.tablet
          : DeviceClass.mobile,
    );
    if (index == null || index < 0 || index >= frames.length) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: _AllFrames(frames: frames),
      );
    }
    final (label, frame) = frames[index];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: _SingleFrame(label: label, child: frame),
    );
  }
}

class _SingleFrame extends StatelessWidget {
  const _SingleFrame({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: colors.surfaceSecondary,
          child: Text(
            label,
            style: styles.caption.copyWith(color: colors.textSecondary),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _AllFrames extends StatelessWidget {
  const _AllFrames({required this.frames});

  final List<(String, Widget)> frames;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final (label, frame) in frames) ...<Widget>[
              Container(
                width: 430,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: colors.surfaceSecondary,
                child: Text(
                  label,
                  style: styles.caption.copyWith(color: colors.textSecondary),
                ),
              ),
              SizedBox(width: 430, height: 700, child: frame),
            ],
          ],
        ),
      ),
    );
  }
}

List<(String, Widget)> _frames() {
  return <(String, Widget)>[
    (
      'Onboarding — default (enable the action)',
      _onboarding(
        SettingsController(actionEnabled: false, onboardingComplete: false),
      ),
    ),
    (
      'Onboarding — consent declined',
      _onboarding(
        SettingsController(
          actionEnabled: false,
          onboardingComplete: false,
          consentModelProcessing: false,
        ),
      ),
    ),
    (
      'Onboarding — action already on (consent only)',
      _onboarding(
        SettingsController(actionEnabled: true, onboardingComplete: false),
      ),
    ),
    ('Home — loaded', _home(history: _seed(), online: true)),
    ('Home — empty', _home(history: const <HistoryEntry>[], online: true)),
    ('Home — offline', _home(history: _seed(), online: false)),
    (
      'Home — action off (how to enable it)',
      _home(
        history: _seed(),
        online: true,
        settings: SettingsController()..actionEnabled = false,
      ),
    ),
    (
      'History — loaded (clips and poster frames kept)',
      _history(
        history: _savedLookups(),
        posters: _posterFrames(),
        clips: _clips(),
      ),
    ),
    (
      'History — poster frame could not be derived',
      _history(history: _savedLookups()),
    ),
    ('History — empty', _history(history: const <HistoryEntry>[])),
    (
      'History — offline (saved clips still replay)',
      _history(
        history: _savedLookups(),
        online: false,
        posters: _posterFrames(),
        clips: _clips(),
      ),
    ),
    ('Clip — serving from library (playing)', _clip('come')),
    ('Clip — sense choice', _clip('bank')),
    ('Clip — rating noted', _clip('come', rating: ClipRating.helpful)),
    (
      'Clip — rating kept for the connection',
      _clip(
        'come',
        online: false,
        rating: ClipRating.notHelpful,
        history: <HistoryEntry>[_savedLibraryHit()],
        clips: _clips(),
      ),
    ),
    (
      'Clip — rating could not be saved',
      _clip(
        'come',
        rating: ClipRating.wrong,
        feedbackApi: MockFeedbackApi()..failStatus = 400,
      ),
    ),
    (
      'Clip — generating',
      _clip('xylograph', api: MockLookupApi(pollsUntilReady: 100000)),
    ),
    (
      'Clip — still making (past the wait threshold)',
      _clip(
        'xylograph',
        api: MockLookupApi(pollsUntilReady: 100000),
        pollInterval: const Duration(milliseconds: 200),
        noticeThreshold: const Duration(milliseconds: 200),
      ),
    ),
    ('Clip — fallback', _clip('quixotic')),
    (
      'Clip — in-context view off (word and phrase only)',
      _clip(
        'come',
        featureFlags: const FixedFeatureFlags(clipViewEnabled: false),
      ),
    ),
    ('Clip — offline', _clip('quixotic', online: false)),
    (
      'Clip — phrase clip (arrives by the clip-ready notice)',
      _clip('once in a while', noticeClip: _phraseClipNotice),
    ),
    (
      'Clip — phrase with no clip (the notice could not come)',
      _clip(
        'tough it out',
        api: MockLookupApi(script: <LookupResult>[_phraseFallback()]),
      ),
    ),
    (
      'Clip — phrase replayed from the device',
      _clip(
        'once in a while',
        clips: _clips(),
        history: <HistoryEntry>[
          HistoryEntry(
            id: 'phrase',
            word: 'once in a while',
            phrase: 'once in a while',
            kind: LookupKind.phrase,
            savedAt: DateTime.now(),
            clipLocalKey: 'phrase',
          ),
        ],
      ),
    ),
    (
      'Clip — error',
      _clip(
        'come',
        api: _ThrowingApi(
          const LookupApiException(500, 'The lookup service is unavailable.'),
        ),
      ),
    ),
    (
      'Clip — allowance exhausted',
      _clip(
        'come',
        entitlement: const Entitlement(
          tier: PlanTier.free,
          signedIn: false,
          lookupsUsed: 20,
          lookupsLimit: 20,
        ),
      ),
    ),
    (
      'Clip — denied (no consent)',
      _clip(
        'come',
        api: MockLookupApi(script: <LookupResult>[_denied()]),
        settings: SettingsController()..consentModelProcessing = false,
      ),
    ),
    (
      'Clip — over-limit selection',
      _clip('the quick brown fox jumps over the lazy dog'),
    ),
    ('Report — default', _clip('come', openReport: true)),
    (
      'Report — phrase (private to the device)',
      _clip('once in a while', noticeClip: _phraseClipNotice, openReport: true),
    ),
    (
      'Report — offline (held for the connection)',
      _clip(
        'come',
        online: false,
        history: <HistoryEntry>[_savedLibraryHit()],
        clips: _clips(),
        openReport: true,
      ),
    ),
    (
      'Report — submitting',
      _clip(
        'come',
        openReport: true,
        reportApi: MockReportApi(latency: const Duration(seconds: 30)),
      ),
    ),
    (
      'Report — could not be sent',
      _clip(
        'come',
        openReport: true,
        reportApi: MockReportApi()..failStatus = 404,
      ),
    ),
    (
      'In place — serving from library (card over the page)',
      _inPlaceClip('come'),
    ),
    ('In place — generating', _inPlaceClip('xylograph')),
    ('In place — empty selection', _inPlaceClip('   ')),
    ('In place — offline', _inPlaceClip('quixotic', online: false)),
    // No auto-open: the reader's own path is driven here so the confirmation
    // that follows a submitted report can be looked at. Tooling only.
    ('Report — submitted (confirmation)', _clip('come')),
    (
      'Account — signed out',
      _account(
        entitlementsApi: MockEntitlementApi(
          error: const EntitlementApiException(
            401,
            'Sign in to see your plan.',
          ),
        ),
      ),
    ),
    (
      'Account — free',
      _account(
        entitlementsApi: MockEntitlementApi(
          plan: const Entitlement(
            tier: PlanTier.free,
            signedIn: true,
            lookupsUsed: 12,
            lookupsLimit: 20,
          ),
        ),
      ),
    ),
    (
      'Account — pro',
      _account(
        entitlementsApi: MockEntitlementApi(
          plan: const Entitlement(
            tier: PlanTier.pro,
            signedIn: true,
            lookupsUsed: 8,
            lookupsLimit: 50,
          ),
        ),
      ),
    ),
    (
      'Account — trial',
      _account(
        entitlementsApi: MockEntitlementApi(
          plan: Entitlement(
            tier: PlanTier.trial,
            signedIn: true,
            lookupsUsed: 3,
            lookupsLimit: 50,
            trialEndsAt: DateTime.now().add(const Duration(days: 5)),
          ),
        ),
      ),
    ),
    (
      'Account — purchasing',
      _account(
        purchases: MockPurchaseService(latency: const Duration(minutes: 5)),
        startPro: true,
      ),
    ),
    (
      'Account — purchase failed',
      _account(
        purchases: MockPurchaseService(
          startProOutcome: const PurchaseFailed(
            'Your payment was declined. Try another payment method.',
          ),
        ),
        startPro: true,
      ),
    ),
    (
      'Account — store unreachable',
      _account(purchases: MockPurchaseService(offline: true), startPro: true),
    ),
    (
      'Account — plan did not load',
      _account(
        entitlementsApi: MockEntitlementApi(
          error: const EntitlementApiException(
            503,
            'The entitlement service is unavailable.',
          ),
        ),
      ),
    ),
    ('Paywall — allowance exhausted (default)', _paywall()),
    (
      'Paywall — purchasing',
      _paywall(
        purchases: MockPurchaseService(latency: const Duration(minutes: 5)),
        tap: PaywallAction.startPro,
      ),
    ),
    (
      'Paywall — purchase failed',
      _paywall(
        purchases: MockPurchaseService(
          startProOutcome: const PurchaseFailed(
            'Your payment was declined. Try another payment method.',
          ),
        ),
        tap: PaywallAction.startPro,
      ),
    ),
    (
      'Paywall — signed out',
      _paywall(
        entitlement: const Entitlement(
          tier: PlanTier.guest,
          signedIn: false,
          lookupsUsed: 20,
          lookupsLimit: 20,
        ),
      ),
    ),
    (
      'Paywall — store unreachable',
      _paywall(purchases: MockPurchaseService(offline: true)),
    ),
    (
      'Paywall — already Pro (top-up only)',
      _paywall(
        entitlement: const Entitlement(
          tier: PlanTier.pro,
          signedIn: true,
          lookupsUsed: 50,
          lookupsLimit: 50,
        ),
      ),
    ),
    (
      'Clip — allowance exhausted (Paywall hidden)',
      _clip(
        'come',
        entitlement: const Entitlement(
          tier: PlanTier.free,
          signedIn: true,
          lookupsUsed: 20,
          lookupsLimit: 20,
        ),
        featureFlags: const FixedFeatureFlags(paidTierEnabled: false),
      ),
    ),
    ('Preferences — default', _preferences(history: _savedLookups())),
    (
      'Preferences — device reduce motion on',
      _preferences(
        history: _savedLookups(),
        settings: SettingsController()..platformReduceMotion = true,
      ),
    ),
    (
      'Preferences — account unreachable',
      _preferences(
        history: _savedLookups(),
        signedIn: true,
        accountApi: MockAccountApi(
          error: const AccountApiException(
            503,
            'Your account is unavailable right now.',
          ),
        ),
        drive: _PreferencesDrive.toggleConsent,
      ),
    ),
    (
      'Preferences — clear-history dialog',
      _preferences(
        history: _savedLookups(),
        drive: _PreferencesDrive.clearDialog,
      ),
    ),
    (
      'Preferences — clearing history',
      _preferences(
        history: _savedLookups(),
        slowClear: true,
        drive: _PreferencesDrive.clearing,
      ),
    ),
  ];
}

Widget _onboarding(SettingsController settings) {
  final services = _services(settings: settings);
  return ScenovaScope(
    services: services,
    child: OnboardingScreen(onComplete: () {}),
  );
}

Widget _home({
  required List<HistoryEntry> history,
  required bool online,
  SettingsController? settings,
}) {
  final services = _services(
    history: history,
    online: online,
    settings: settings,
  );
  return ScenovaScope(
    services: services,
    child: HomeScreen(router: AppRouter(services: services)),
  );
}

/// The History screen, with the clips and poster frames the device keeps.
Widget _history({
  required List<HistoryEntry> history,
  bool online = true,
  PosterFrameStore? posters,
  ClipStore? clips,
}) {
  final services = _services(
    history: history,
    online: online,
    posterFrames: posters,
    clips: clips,
  );
  return ScenovaScope(
    services: services,
    child: HistoryScreen(router: AppRouter(services: services)),
  );
}

/// The Preferences screen, with the reader's settings, device history, and the
/// account store.
///
/// [drive] exercises the states that need an interaction: the account notice
/// after a signed-in choice could not reach the account, the clear-history
/// dialog, and the clearing state while the clear runs. [slowClear] holds the
/// clear open so the clearing state stays on screen.
Widget _preferences({
  List<HistoryEntry> history = const <HistoryEntry>[],
  SettingsController? settings,
  bool online = true,
  bool signedIn = false,
  AccountApi? accountApi,
  bool slowClear = false,
  _PreferencesDrive drive = _PreferencesDrive.none,
}) {
  final services = _services(
    settings: settings,
    history: history,
    historyStore: slowClear ? _SlowHistoryStore(seed: history) : null,
    online: online,
    accountSession: DevelopmentAccountSession(signedIn: signedIn),
    accountApi: accountApi,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewPreferences(services: services, drive: drive),
  );
}

/// What a Preferences preview does once the screen has loaded.
enum _PreferencesDrive { none, toggleConsent, clearDialog, clearing }

/// Drives the Preferences screen through a state the gallery needs to show.
class _PreviewPreferences extends StatefulWidget {
  const _PreviewPreferences({required this.services, required this.drive});

  final ScenovaServices services;
  final _PreferencesDrive drive;

  @override
  State<_PreviewPreferences> createState() => _PreviewPreferencesState();
}

class _PreviewPreferencesState extends State<_PreviewPreferences> {
  PreferencesController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.drive == _PreferencesDrive.none) return;
    final controller = PreferencesController(services: widget.services);
    _controller = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drive(controller));
  }

  Future<void> _drive(PreferencesController controller) async {
    await controller.load();
    if (!mounted) return;
    switch (widget.drive) {
      case _PreferencesDrive.none:
        break;
      case _PreferencesDrive.toggleConsent:
        await controller.setConsent(false);
      case _PreferencesDrive.clearDialog:
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              ClearHistoryDialog(onConfirm: controller.clearHistory),
        );
      case _PreferencesDrive.clearing:
        // The clear is held open by the slow store, so the row's spinner and
        // the dialog's progress state both stay on screen.
        await controller.clearHistory();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      PreferencesScreen(controller: _controller);
}

/// A history whose clear never resolves, so the clearing state can be looked at.
class _SlowHistoryStore extends InMemoryHistoryStore {
  _SlowHistoryStore({super.seed});

  @override
  Future<void> clear() => Future<void>.delayed(const Duration(minutes: 30));
}

/// The Account screen, driven through the scripted entitlement, session, and
/// store.
///
/// [startPro] taps the primary action once the plan has loaded, so the
/// purchasing, purchase-failed, and store-unreachable states can be looked at.
Widget _account({
  EntitlementApi? entitlementsApi,
  AccountSession? accountSession,
  PurchaseService? purchases,
  bool startPro = false,
}) {
  final services = _services(
    entitlementsApi: entitlementsApi,
    accountSession: accountSession,
    purchases: purchases,
  );
  final controller = AccountController(
    entitlements: services.entitlementsApi,
    session: services.accountSession,
    purchases: services.purchases,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewAccount(controller: controller, startPro: startPro),
  );
}

/// Loads the plan and, when asked, starts a purchase, so an action's states are
/// on screen for the frame. Tooling only.
class _PreviewAccount extends StatefulWidget {
  const _PreviewAccount({required this.controller, required this.startPro});

  final AccountController controller;
  final bool startPro;

  @override
  State<_PreviewAccount> createState() => _PreviewAccountState();
}

class _PreviewAccountState extends State<_PreviewAccount> {
  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    unawaited(
      controller.load().then((_) async {
        if (widget.startPro) await controller.startPro();
      }),
    );
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AccountScreen(controller: widget.controller);
}

/// The Paywall sheet, driven through the scripted store.
///
/// [tap] fires one of the purchase actions once the offering has loaded, so the
/// purchasing and purchase-failed states can be looked at. Tooling only.
Widget _paywall({
  Entitlement entitlement = _exhaustedFreePreview,
  PurchaseService? purchases,
  AccountSession? accountSession,
  PaywallAction? tap,
}) {
  final services = _services(
    entitlement: entitlement,
    purchases: purchases,
    accountSession: accountSession,
  );
  final controller = PaywallController(
    entitlement: entitlement,
    purchases: services.purchases,
    session: services.accountSession,
    analytics: services.analytics,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewPaywall(
      controller: controller,
      entitlement: entitlement,
      tap: tap,
    ),
  );
}

/// The Free plan at its limit, for the Paywall frames. Tooling only.
const Entitlement _exhaustedFreePreview = Entitlement(
  tier: PlanTier.free,
  signedIn: true,
  lookupsUsed: 20,
  lookupsLimit: 20,
);

/// Opens the Paywall sheet with a prepared controller, so one state per frame is
/// on screen. Tooling only.
class _PreviewPaywall extends StatefulWidget {
  const _PreviewPaywall({
    required this.controller,
    required this.entitlement,
    this.tap,
  });

  final PaywallController controller;
  final Entitlement entitlement;
  final PaywallAction? tap;

  @override
  State<_PreviewPaywall> createState() => _PreviewPaywallState();
}

class _PreviewPaywallState extends State<_PreviewPaywall> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    await widget.controller.load();
    if (!mounted) return;
    unawaited(
      showPaywallSheet(
        context,
        entitlement: widget.entitlement,
        controller: widget.controller,
      ),
    );
    final action = widget.tap;
    if (action == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        action == PaywallAction.startPro
            ? widget.controller.startPro()
            : widget.controller.buyTopUp(),
      );
    });
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

/// Two saved lookups for the History frames.
///
/// The first carries the clip and the poster frame a device kept from it; the
/// second carries neither, so the row falls back to the shared still-frame
/// stand-in (`FEAT-009` → Edge Cases).
List<HistoryEntry> _savedLookups() {
  final now = DateTime.now();
  return <HistoryEntry>[
    HistoryEntry(
      id: 'come-1',
      word: 'come',
      phrase: 'to move towards someone or something',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(minutes: 6)),
      clipUrl: 'https://clips.example/come.mp4',
      clipLocalKey: 'come-1',
      posterLocalKey: 'come-1',
    ),
    HistoryEntry(
      id: 'bank-1',
      word: 'bank',
      phrase: 'a place that keeps money safe',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(hours: 2)),
      clipUrl: 'https://clips.example/bank.mp4',
    ),
  ];
}

/// The clips the History frames hold, keyed by the entry that owns them.
///
/// The gallery runs on the web, where there is no device store, so a kept clip
/// is the bundled walkthrough clip's own URL: the replay frames play something
/// real rather than a source the browser cannot open. Tooling only.
ClipStore _clips() => InMemoryClipStore(
  seed: <String, String>{'come-1': _keptClipSource, 'phrase': _keptClipSource},
);

/// A source the preview can actually play, standing in for a clip the device
/// kept. Tooling only.
String get _keptClipSource => Uri.base
    .resolve('assets/assets/motion/first-run-walkthrough.mp4')
    .toString();

/// The poster frames the History frames draw, keyed by the entry that owns
/// them. Tooling only: a device derives its own from the clip.
PosterFrameStore _posterFrames() => InMemoryPosterFrameStore(
  seed: <String, Uint8List>{'come-1': base64Decode(_posterFrameJpeg)},
);

/// A small still standing in for a frame derived from a clip, so the poster
/// path can be looked at without a device. Tooling only.
const String _posterFrameJpeg =
    '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';

Widget _clip(
  String selection, {
  LookupApi? api,
  bool online = true,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  SettingsController? settings,
  ClipPresentation presentation = ClipPresentation.page,
  Duration? pollInterval,
  Duration? noticeThreshold,
  List<HistoryEntry> history = const <HistoryEntry>[],
  ClipStore? clips,
  FeatureFlags featureFlags = const FixedFeatureFlags(),
  Clip? noticeClip,
  FeedbackApi? feedbackApi,
  ClipRating? rating,
  ReportApi? reportApi,
  bool openReport = false,
}) {
  final noticeSource = ScriptedClipNoticeSource();
  final services = _services(
    api: api,
    online: online,
    entitlement: entitlement,
    settings: settings,
    history: history,
    clips: clips,
    featureFlags: featureFlags,
    clipNoticeSource: noticeSource,
    feedbackApi: feedbackApi,
    reportApi: reportApi,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewClip(
      services: services,
      selection: selection,
      presentation: presentation,
      pollInterval: pollInterval,
      noticeThreshold: noticeThreshold,
      noticeSource: noticeSource,
      noticeClip: noticeClip,
      rating: rating,
      openReport: openReport,
    ),
  );
}

/// A saved lookup the device holds with the service lookup it came from, so the
/// offline frames replay it and can still rate it.
HistoryEntry _savedLibraryHit() {
  return HistoryEntry(
    id: 'come-1',
    word: 'come',
    phrase: 'to move towards someone or something',
    kind: LookupKind.word,
    savedAt: DateTime.now(),
    clipUrl: 'mock://clip/library-hit',
    clipLocalKey: 'come-1',
    lookupId: 'lookup-come',
  );
}

/// The clip a clip-ready notice carries in the preview. It is not a stream, so
/// the player keeps its poster; the state is what the frame shows.
const Clip _phraseClipNotice = Clip(
  url: 'mock://clip/generated',
  durationSeconds: 4,
  resolution: '360p',
  hasAudio: false,
);

/// The clip view as the in-place hosts present it — the iOS share extension's
/// sheet and the Android selection action: the compact card over a reading page,
/// with the page visible around and behind it.
Widget _inPlaceClip(String selection, {bool online = true}) {
  return Stack(
    children: <Widget>[
      const _ReadingPage(),
      _clip(selection, online: online, presentation: ClipPresentation.inPlace),
    ],
  );
}

/// A stand-in for the reading app behind the sheet. Tooling only.
class _ReadingPage extends StatelessWidget {
  const _ReadingPage();

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    return ColoredBox(
      color: colors.surfaceSecondary,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final width in <double>[0.9, 1.0, 0.95, 1.0, 0.6])
              Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.md),
                child: FractionallySizedBox(
                  widthFactor: width,
                  child: Container(
                    height: tokens.spacing.sm,
                    decoration: BoxDecoration(
                      color: colors.border,
                      borderRadius: BorderRadius.circular(ScenovaRadius.sm),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

ScenovaServices _services({
  LookupApi? api,
  List<HistoryEntry> history = const <HistoryEntry>[],
  HistoryStore? historyStore,
  bool online = true,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  EntitlementApi? entitlementsApi,
  AccountSession? accountSession,
  AccountApi? accountApi,
  PurchaseService? purchases,
  SettingsController? settings,
  FeatureFlags featureFlags = const FixedFeatureFlags(),
  ClipNoticeSource? clipNoticeSource,
  NotificationPermissionGate notificationPermission =
      const PlatformNotificationPermission(),
  FeedbackApi? feedbackApi,
  PendingFeedbackStore? feedbackStore,
  ReportApi? reportApi,
  PendingReportStore? reportStore,
  ReportedClipStore? reportedClipStore,
  PosterFrameStore? posterFrames,
  ClipStore? clips,
}) {
  final connectivity = ManualConnectivity(online: online);
  final settingsController = settings ?? SettingsController();
  final resolvedHistory = historyStore ?? InMemoryHistoryStore(seed: history);
  final resolvedClips = clips ?? InMemoryClipStore();
  final resolvedPosters = posterFrames ?? InMemoryPosterFrameStore();
  final pushRegistrar = PushRegistrar(
    api: MockPushRegistrationApi(),
    tokens: DevelopmentPushTokenProvider(token: 'preview-push'),
    connectivity: connectivity,
  );
  final clipNotices = ClipNoticeInbox(
    source: clipNoticeSource ?? ScriptedClipNoticeSource(),
  );
  final savedClips = SavedClipKeeper(
    history: resolvedHistory,
    clips: resolvedClips,
    posters: resolvedPosters,
  );
  return ScenovaServices(
    lookupApi: api ?? MockLookupApi(),
    identity: AnonymousIdentity(subject: 'preview'),
    historyStore: resolvedHistory,
    connectivity: connectivity,
    settings: settingsController,
    entitlements: FixedEntitlementProvider(entitlement),
    entitlementsApi: entitlementsApi ?? MockEntitlementApi(),
    accountSession: accountSession ?? DevelopmentAccountSession(),
    accountApi: accountApi ?? MockAccountApi(),
    purchases: purchases ?? MockPurchaseService(),
    captureChannel: CaptureChannel(),
    analytics: AnalyticsClient(
      api: MockAnalyticsApi(),
      settings: settingsController,
      connectivity: connectivity,
      anonymousId: 'preview',
      appVersion: 'preview',
      locale: 'en-GB',
    ),
    pushRegistrar: pushRegistrar,
    clipNotices: clipNotices,
    notificationPermission: notificationPermission,
    featureFlags: featureFlags,
    feedbackOutbox: FeedbackOutbox(
      api: feedbackApi ?? MockFeedbackApi(),
      store: feedbackStore ?? InMemoryPendingFeedbackStore(),
      connectivity: connectivity,
    ),
    reportOutbox: ReportOutbox(
      api: reportApi ?? MockReportApi(),
      store: reportStore ?? InMemoryPendingReportStore(),
      connectivity: connectivity,
    ),
    reportedClips: ReportedClipWatch(
      history: resolvedHistory,
      savedClips: savedClips,
      store: reportedClipStore ?? InMemoryReportedClipStore(),
      push: pushRegistrar,
      notices: clipNotices,
    ),
    savedClips: savedClips,
    posterFrames: resolvedPosters,
    clips: resolvedClips,
    locale: 'en-GB',
  );
}

List<HistoryEntry> _seed() {
  final now = DateTime.now();
  return <HistoryEntry>[
    HistoryEntry(
      id: 'a',
      word: 'come',
      phrase: 'to move towards someone or something',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(minutes: 6)),
      clipUrl: 'mock://clip/library-hit',
    ),
    HistoryEntry(
      id: 'b',
      word: 'bank',
      phrase: 'a place that keeps money safe',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(hours: 2)),
      clipUrl: 'mock://clip/bank-money',
    ),
  ];
}

class _PreviewClip extends StatefulWidget {
  const _PreviewClip({
    required this.services,
    required this.selection,
    this.presentation = ClipPresentation.page,
    this.pollInterval,
    this.noticeThreshold,
    this.noticeSource,
    this.noticeClip,
    this.rating,
    this.openReport = false,
  });

  final ScenovaServices services;
  final String selection;
  final ClipPresentation presentation;
  final Duration? pollInterval;
  final Duration? noticeThreshold;

  /// The scripted notice intake, when this frame shows a clip that arrives by
  /// the clip-ready notice.
  final ScriptedClipNoticeSource? noticeSource;

  /// The clip the notice carries, when the frame shows that path.
  final Clip? noticeClip;

  /// The rating this frame shows the reader having given, so the delivery state
  /// is visible without a tap. Tooling only.
  final ClipRating? rating;

  /// Whether this frame opens the Report sheet over the clip once it plays, so
  /// the sheet's states can be looked at. Tooling only.
  final bool openReport;

  @override
  State<_PreviewClip> createState() => _PreviewClipState();
}

class _PreviewClipState extends State<_PreviewClip> {
  late final ClipViewController _controller = ClipViewController(
    services: widget.services,
    selection: CaptureSelection.parse(widget.selection),
    pollInterval: widget.pollInterval,
    noticeThreshold: widget.noticeThreshold,
  );

  bool _noticeDelivered = false;
  bool _rated = false;
  bool _reportOpened = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _deliverNoticeOnce();
    _rateOnce();
    _openReportOnce();
  }

  /// Delivers the clip-ready notice for the lookup once the view is waiting on
  /// it, as the notification service would. Tooling only.
  void _deliverNoticeOnce() {
    final clip = widget.noticeClip;
    final source = widget.noticeSource;
    final lookupId = _controller.result?.lookupId;
    if (_noticeDelivered ||
        clip == null ||
        source == null ||
        lookupId == null) {
      return;
    }
    _noticeDelivered = true;
    source.deliver(
      ClipNotice(
        lookupId: lookupId,
        clipUrl: clip.url,
        durationSeconds: clip.durationSeconds,
        resolution: clip.resolution,
        hasAudio: clip.hasAudio,
      ),
    );
  }

  /// Rates the clip once it is on screen, so a delivery state can be looked at.
  void _rateOnce() {
    final rating = widget.rating;
    if (_rated || rating == null) return;
    if (_controller.phase != ClipPhase.playing) return;
    _rated = true;
    unawaited(_controller.markFeedback(rating));
  }

  /// Opens the Report sheet once the clip plays, so its states can be looked at
  /// without a tap. Tooling only.
  void _openReportOnce() {
    if (_reportOpened || !widget.openReport) return;
    if (_controller.phase != ClipPhase.playing) return;
    _reportOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showReportSheet(
          context,
          word: _controller.word,
          privateToDevice: _controller.isPhrase,
          offline: !widget.services.connectivity.isOnline,
          onSubmit: (reason, note) =>
              _controller.submitReport(reason, note: note),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final inPlace = widget.presentation == ClipPresentation.inPlace;
    return ClipViewScreen(
      controller: _controller,
      presentation: widget.presentation,
      // The app wires these to the router; the preview only needs the controls
      // to render, so they are inert here.
      onDismiss: () {},
      onOpenHistory: inPlace ? null : () {},
    );
  }
}

class _ThrowingApi implements LookupApi {
  _ThrowingApi(this.error);

  final LookupApiException error;

  @override
  Future<LookupResult> createLookup(LookupRequest request) async => throw error;

  @override
  Future<LookupResult> getLookup(String lookupId) async => throw error;
}

LookupResult _denied() => const LookupResult(
  lookupId: 'denied',
  kind: LookupKind.word,
  rawSelection: 'come',
  normalisedLemma: 'come',
  status: LookupStatus.denied,
  senses: <Sense>[],
  notice: null,
  correlationId: 'preview',
);

/// A phrase the provider declined: the phrase shows with the clip unavailable
/// and a retry, and nothing is stored (`FEAT-007`).
LookupResult _phraseFallback() => const LookupResult(
  lookupId: 'phrase-fallback',
  kind: LookupKind.phrase,
  rawSelection: 'tough it out',
  normalisedLemma: null,
  status: LookupStatus.fallback,
  senses: <Sense>[
    Sense(senseLabel: '1', partOfSpeech: '', glossPhrase: 'tough it out'),
  ],
  notice: null,
  correlationId: 'preview',
);
