// Development preview gallery.
//
// Renders one screen state per page so the design can be looked at in a browser
// without a reading app: `?frame=<n>`, add `?dark=1` for the dark theme and
// `?device=tablet` for the tablet device class. Built with `flutter build web -t tool/preview_main.dart`; this is tooling, never
// shipped.
import 'package:flutter/material.dart';
import 'package:scenova/app_router.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/services/analytics.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/identity.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_registrar.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/theme/typography.dart';

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
    ('Clip — serving from library (playing)', _clip('come')),
    ('Clip — sense choice', _clip('bank')),
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
    ('Clip — offline', _clip('quixotic', online: false)),
    (
      'Clip — phrase clip (generated, kept on the device)',
      _clip('once in a while'),
    ),
    (
      'Clip — phrase replayed from the device',
      _clip(
        'once in a while',
        history: <HistoryEntry>[
          HistoryEntry(
            id: 'phrase',
            word: 'once in a while',
            phrase: 'once in a while',
            kind: LookupKind.phrase,
            savedAt: DateTime.now(),
            clipUrl: 'device://once-in-a-while',
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
          lookupsRemaining: 0,
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
    (
      'Extension — serving from library (card over the page)',
      _extensionClip('come'),
    ),
    ('Extension — generating', _extensionClip('xylograph')),
    ('Extension — empty selection', _extensionClip('   ')),
    ('Extension — offline', _extensionClip('quixotic', online: false)),
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
}) {
  final services = _services(
    api: api,
    online: online,
    entitlement: entitlement,
    settings: settings,
    history: history,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewClip(
      services: services,
      selection: selection,
      presentation: presentation,
      pollInterval: pollInterval,
      noticeThreshold: noticeThreshold,
    ),
  );
}

/// The clip view as the iOS share extension presents it: the compact card over
/// a reading page, with the page visible around and behind it.
Widget _extensionClip(String selection, {bool online = true}) {
  return Stack(
    children: <Widget>[
      const _ReadingPage(),
      _clip(
        selection,
        online: online,
        presentation: ClipPresentation.extension,
      ),
    ],
  );
}

/// A stand-in for the reading app behind the extension sheet. Tooling only.
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
  bool online = true,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  SettingsController? settings,
}) {
  final connectivity = ManualConnectivity(online: online);
  final settingsController = settings ?? SettingsController();
  return ScenovaServices(
    lookupApi: api ?? MockLookupApi(),
    identity: AnonymousIdentity(subject: 'preview'),
    historyStore: InMemoryHistoryStore(seed: history),
    connectivity: connectivity,
    settings: settingsController,
    entitlements: FixedEntitlementProvider(entitlement),
    captureChannel: CaptureChannel(),
    analytics: AnalyticsClient(
      api: MockAnalyticsApi(),
      settings: settingsController,
      connectivity: connectivity,
      anonymousId: 'preview',
      appVersion: 'preview',
      locale: 'en-GB',
    ),
    pushRegistrar: PushRegistrar(
      api: MockPushRegistrationApi(),
      tokens: DevelopmentPushTokenProvider(token: 'preview-push'),
      connectivity: connectivity,
    ),
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
  });

  final ScenovaServices services;
  final String selection;
  final ClipPresentation presentation;
  final Duration? pollInterval;
  final Duration? noticeThreshold;

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isExtension = widget.presentation == ClipPresentation.extension;
    return ClipViewScreen(
      controller: _controller,
      presentation: widget.presentation,
      // The app wires these to the router; the preview only needs the controls
      // to render, so they are inert here.
      onDismiss: () {},
      onOpenHistory: isExtension ? null : () {},
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
