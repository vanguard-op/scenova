/// The clip media the shared Clip Player draws.
///
/// Each app's own clip model implements this — the reader app's lookup result
/// and the console's review entry carry the same four facts — so the player
/// takes one shape without either app handing it its model.
abstract interface class ClipSource {
  /// The clip's source URL.
  ///
  /// A clip served by the product is an http(s) URL; a clip the device kept for
  /// offline replay is a `file:` URL in the device's own store.
  String get url;

  /// The clip's length in seconds, or zero when the service reports none.
  double get durationSeconds;

  /// The clip's frame size, such as `360p`.
  String get resolution;

  /// Whether the clip carries an audio track.
  bool get hasAudio;
}

/// Whether [url] is a source the platform can open.
///
/// The product's clips are served over http(s), and a clip the device kept
/// replays from the device's own store over `file`, so both are opened. A saved
/// placeholder or a scripted development source is neither, so a surface keeps
/// its still frame rather than asking the platform to open something it cannot
/// play.
bool isPlayableClipUrl(String url) {
  if (url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'file';
}
