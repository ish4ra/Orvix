class SubtitleRenderPolicy {
  const SubtitleRenderPolicy._();

  static bool flutterOverlayVisible({
    required bool aiSinhalaRequested,
    required bool isNativePlayer,
  }) {
    // Native playback uses libass. Do not flatten ASS/SSA into SubtitleView.
    if (aiSinhalaRequested) return false;
    return !isNativePlayer;
  }

  static bool nativeSubtitleVisible({
    required bool requestedVisible,
  }) {
    return requestedVisible;
  }
}
