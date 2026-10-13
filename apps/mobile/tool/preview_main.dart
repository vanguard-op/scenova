// Development preview gallery.
//
// Renders one screen state per page so the design can be looked at in a browser
// without a reading app: `?frame=0` … `?frame=11`. Built with
// `flutter build web -t tool/preview_main.dart`; this is tooling, never shipped.
import 'package:flutter/material.dart';
import 'package:scenova/app_router.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
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
    final raw = Uri.base.queryParameters['frame'];
    final index = raw == null ? null : int.tryParse(raw);
    final theme = AppTheme.build(
      brightness: Brightness.light,
      deviceClass: DeviceClass.mobile,
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
    ('Home — loaded', _home(history: _seed(), online: true)),
    ('Home — empty', _home(history: const <HistoryEntry>[], online: true)),
    ('Home — offline', _home(history: _seed(), online: false)),
    ('Clip — serving from library (playing)', _clip('come')),
    ('Clip — sense choice', _clip('bank')),
    (
      'Clip — generating',
      _clip('xylograph', api: MockLookupApi(pollsUntilReady: 100000)),
    ),
    ('Clip — fallback', _clip('quixotic')),
    ('Clip — offline', _clip('quixotic', online: false)),
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
  ];
}

Widget _home({required List<HistoryEntry> history, required bool online}) {
  final services = _services(history: history, online: online);
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
}) {
  final services = _services(
    api: api,
    online: online,
    entitlement: entitlement,
    settings: settings,
  );
  return ScenovaScope(
    services: services,
    child: _PreviewClip(services: services, selection: selection),
  );
}

ScenovaServices _services({
  LookupApi? api,
  List<HistoryEntry> history = const <HistoryEntry>[],
  bool online = true,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  SettingsController? settings,
}) {
  return ScenovaServices(
    lookupApi: api ?? MockLookupApi(),
    historyStore: InMemoryHistoryStore(seed: history),
    connectivity: ManualConnectivity(online: online),
    settings: settings ?? SettingsController(),
    entitlements: FixedEntitlementProvider(entitlement),
    captureChannel: CaptureChannel(),
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
  const _PreviewClip({required this.services, required this.selection});

  final ScenovaServices services;
  final String selection;

  @override
  State<_PreviewClip> createState() => _PreviewClipState();
}

class _PreviewClipState extends State<_PreviewClip> {
  late final ClipViewController _controller = ClipViewController(
    services: widget.services,
    selection: CaptureSelection.parse(widget.selection),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipViewScreen(controller: _controller);
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
