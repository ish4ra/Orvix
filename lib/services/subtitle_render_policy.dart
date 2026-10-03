class SubtitleRenderPolicy {
  const SubtitleRenderPolicy._();

  static bool flutterOverlayVisible({
    required bool aiSinhalaRequested,
    required bool isAndroid,
    required bool isNativePlayer,
  }) {
    if (aiSinhalaRequested) return false;
    if (isAndroid) return true;
    return !isNativePlayer;
  }

  static bool nativeSubtitleVisible({
    required bool requestedVisible,
    required bool aiSinhalaRequested,
    required bool isAndroid,
    required bool isBitmapTrack,
  }) {
    if (!requestedVisible) return false;
    if (aiSinhalaRequested) return true;
    if (isAndroid) return isBitmapTrack;
    return true;
  }
}
