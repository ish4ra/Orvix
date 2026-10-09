# Legacy iOS FFmpegKit stand-in

Orvix uses FFmpegKit only for embedded subtitle extraction and the AI audio
subtitle fallback, and both are already disabled on iOS
(`EmbeddedSubtitleExtractorService.isSupportedPlatform` and the platform check
in `AiAudioSttService`). The real `ffmpeg_kit_flutter_new_https` iOS pod needs
iOS 14 and ships FFmpeg frameworks built for iOS 14, so it cannot go into the
iOS 12 Legacy IPA.

`tools/build_ios_legacy_ipa.sh` points the Legacy build at this package
through a generated `pubspec_overrides.yaml`. It mirrors only the Dart API
Orvix uses. It has no plugin section, so no native code is linked, and every
FFmpeg/FFprobe call fails the way a failed FFmpeg session would, without
running anything. Android, Android TV, Windows, macOS and the Modern iOS
build never use it.
