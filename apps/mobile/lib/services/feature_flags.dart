import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';

import '../config.dart';
import 'firebase_client.dart';

/// The client-side release flags the reader's build honours
/// (`docs/Scenova/release.md` → "Rollout Phases & Feature Flags").
///
/// These are the flags that change what the reader's own build shows, as
/// opposed to the service-side flags each service reads from its environment. A
/// flag here is a kill switch: it has to be changeable without a store release,
/// so its runtime source is Firebase Remote Config rather than a compile-time
/// `--dart-define`.
abstract interface class FeatureFlags {
  /// `enable_clip_view`: whether the in-context clip view is shown. When it is
  /// off, the reader sees the selected word and its phrase with no clip.
  bool get clipViewEnabled;

  /// `enable_offline_history`: whether a saved clip replays with no connection.
  /// When it is off, offline replay is disabled while the on-device history
  /// stays.
  bool get offlineHistoryEnabled;

  /// Fetches the latest values from the runtime source and applies them.
  ///
  /// Best-effort: a fetch that fails, or a source that is not configured on this
  /// platform, leaves the last known values in place, so a kill switch never
  /// trips by accident when the device is offline.
  Future<void> refresh();
}

/// Reads the release flags from Firebase Remote Config.
///
/// Remote Config is the runtime source because the flag has to be flippable
/// inside the release's recovery target (`docs/Scenova/release.md` → "Rollback &
/// Roll-forward"): a store build cannot be recalled to disable a misbehaving
/// surface, so the client's rollback path is always the flag.
///
/// The in-app default is the flag's rolled-out state, not the dark-launch
/// default, so a fetch that has not landed yet keeps the shipped feature
/// working; a Remote Config value of `false` is what disables it.
class RemoteConfigFeatureFlags implements FeatureFlags {
  RemoteConfigFeatureFlags({
    bool? clipViewDefault,
    bool? offlineHistoryDefault,
    Future<FirebaseApp> Function()? initialize,
    FirebaseRemoteConfig? remoteConfigOverride,
  }) : _clipViewEnabled = clipViewDefault ?? AppConfig.clipViewEnabledByDefault,
       _offlineHistoryEnabled =
           offlineHistoryDefault ?? AppConfig.offlineHistoryEnabledByDefault,
       _initialize = initialize ?? initializeFirebaseClient,
       _remoteConfig = remoteConfigOverride;

  /// The Remote Config parameter name, matching the flag in `release.md`.
  static const String clipViewKey = 'enable_clip_view';

  /// The Remote Config parameter name for the offline-replay kill switch.
  static const String offlineHistoryKey = 'enable_offline_history';

  bool _clipViewEnabled;
  bool _offlineHistoryEnabled;
  final Future<FirebaseApp> Function() _initialize;
  FirebaseRemoteConfig? _remoteConfig;

  @override
  bool get clipViewEnabled => _clipViewEnabled;

  @override
  bool get offlineHistoryEnabled => _offlineHistoryEnabled;

  @override
  Future<void> refresh() async {
    try {
      final remote = await _remote();
      await remote.setDefaults(<String, Object>{
        clipViewKey: AppConfig.clipViewEnabledByDefault,
        offlineHistoryKey: AppConfig.offlineHistoryEnabledByDefault,
      });
      await remote.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: AppConfig.remoteConfigFetchTimeout,
          minimumFetchInterval: AppConfig.remoteConfigFetchInterval,
        ),
      );
      await remote.fetchAndActivate();
      _clipViewEnabled = remote.getBool(clipViewKey);
      _offlineHistoryEnabled = remote.getBool(offlineHistoryKey);
    } on Object {
      // The flag source is unreachable or unconfigured on this platform; the
      // last known value stands rather than the feature flipping off by
      // accident.
    }
  }

  Future<FirebaseRemoteConfig> _remote() async {
    final existing = _remoteConfig;
    if (existing != null) return existing;
    await _initialize();
    return _remoteConfig = FirebaseRemoteConfig.instance;
  }
}

/// Flags fixed for the life of the process.
///
/// Used by tests and by the development preview gallery, which show one state
/// per page and never talk to the flag source.
class FixedFeatureFlags implements FeatureFlags {
  const FixedFeatureFlags({
    this.clipViewEnabled = true,
    this.offlineHistoryEnabled = true,
  });

  @override
  final bool clipViewEnabled;

  @override
  final bool offlineHistoryEnabled;

  @override
  Future<void> refresh() async {}
}
