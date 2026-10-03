class SubtitleRenderPolicy {
  const SubtitleRenderPolicy._();

  static bool flutterOverlayVisible({
    required bool aiSinhalaRequested,
    required bool isAndroid,
    required bool isNativePlayer,
    required bool nativeStyledSubtitles,
  }) {
    if (aiSinhalaRequested) return false;
    if (isAndroid) return !nativeStyledSubtitles;
    return !isNativePlayer;
  }

  static bool nativeSubtitleVisible({
    required bool requestedVisible,
    required bool aiSinhalaRequested,
    required bool isAndroid,
    required bool isBitmapTrack,
    required bool nativeStyledSubtitles,
  }) {
    if (!requestedVisible) return false;
    if (aiSinhalaRequested) return true;
    if (isAndroid) {
      return nativeStyledSubtitles || isBitmapTrack;
    }
    return true;
  }
}
