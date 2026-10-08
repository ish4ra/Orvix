# Third-party notices

Orvix's own source code is licensed under [AGPL-3.0-only](LICENSE). Orvix release packages also contain third-party open-source components. **Those components stay under their own licenses.** They are not relicensed under the AGPL, and Orvix claims no ownership of them.

This file lists the main components distributed in Orvix packages. It is a guide, not a replacement for the upstream license texts. Where an upstream project offers several license variants, the variant that applies is the one of the exact build Orvix bundles. Check the linked upstream project for that build's terms.

Full license texts:

- **Dart/Flutter packages and the Flutter engine:** every Flutter build includes the combined license notices of all packages it was built with (`data/flutter_assets/NOTICES.Z` on Windows). The packages are listed in [`pubspec.yaml`](pubspec.yaml) and [`pubspec.lock`](pubspec.lock).
- **stream-server:** [`licenses/stream-server/`](licenses/stream-server/), copied into Windows packages as `licenses/stream-server/`.
- **FFmpeg tools:** the build source and checksum are recorded in `licenses/ffmpeg/NOTICE.txt` inside Windows packages.
- **Noto Sans Sinhala font:** [`assets/fonts/OFL.txt`](assets/fonts/OFL.txt).

## Windows (installer and portable ZIP)

| Component | Files | License | Upstream |
|---|---|---|---|
| Flutter engine and framework | `flutter_windows.dll`, `data/` | BSD-3-Clause, plus the licenses of the engine's own third-party code (see `NOTICES.Z`) | https://github.com/flutter/flutter |
| media_kit, media_kit_video (pinned fork) | Dart code, `media_kit_video_plugin.dll` | MIT | https://github.com/media-kit/media-kit, fork at https://github.com/varunsalian/debrify (`packages/media_kit_patched`, `packages/media_kit_video_patched`) |
| media_kit_libs_windows_video | plugin code | MIT | https://github.com/media-kit/media-kit |
| libmpv (with the libraries it is built with, including FFmpeg) | `libmpv-2.dll` | LGPL-2.1-or-later. The media-kit build configures mpv with `-Dgpl=false` and FFmpeg with `--disable-gpl`. Bundled libraries keep their own licenses | https://mpv.io, build: https://github.com/media-kit/libmpv-win32-video-build |
| ANGLE | `libEGL.dll`, `libGLESv2.dll` | BSD-3-Clause | https://chromium.googlesource.com/angle/angle, build: https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES |
| SwiftShader | `vk_swiftshader.dll` | Apache-2.0 | https://github.com/google/swiftshader (shipped in the same ANGLE build) |
| Vulkan loader | `vulkan-1.dll` | Apache-2.0 | https://github.com/KhronosGroup/Vulkan-Loader (shipped in the same ANGLE build) |
| Microsoft D3D shader compiler | `d3dcompiler_47.dll` | Microsoft redistributable system component, not open source | Shipped in the same ANGLE build. Part of Windows / the Windows SDK |
| FFmpegKit (ffmpeg_kit_flutter_new_https) | `libffmpegkit.dll` and bundled FFmpeg DLLs | LGPL-3.0 (wrapper), FFmpeg libraries under their LGPL build terms | https://github.com/sk3llo/ffmpeg_kit_flutter |
| FFmpeg command-line tools (LGPL build) | `tools/ffmpeg/bin/ffmpeg.exe`, `ffprobe.exe` | LGPL-2.1-or-later (BtbN `lgpl` variant) | https://ffmpeg.org, build: https://github.com/BtbN/FFmpeg-Builds |
| stream-server (with Orvix modifications) | `orvix-stream-server.exe` | MIT, Copyright (c) 2025 perpetus | https://github.com/stremio-native/stream-server. Orvix's patch: [`tools/patch_orvix_stream_server.py`](tools/patch_orvix_stream_server.py), [`docs/ORVIX_STREAM_SERVER_MOD.md`](docs/ORVIX_STREAM_SERVER_MOD.md) |
| flutter_secure_storage_windows | plugin DLL | BSD-3-Clause | https://github.com/mogol/flutter_secure_storage |
| url_launcher_windows | plugin DLL | BSD-3-Clause | https://github.com/flutter/packages |
| window_manager, screen_retriever_windows | plugin DLLs | MIT | https://github.com/leanflutter |
| app_links | plugin DLL | Apache-2.0 | https://github.com/llfbandit/app_links |
| jni | FFI library | BSD-3-Clause | https://github.com/dart-lang/native |
| Inno Setup | installer and uninstaller runtime (`unins000.exe`) | Inno Setup License | https://jrsoftware.org/isinfo.php |

## All platforms

| Component | License | Upstream |
|---|---|---|
| Noto Sans Sinhala (subtitle font) | SIL Open Font License 1.1 | https://github.com/notofonts/sinhala |
| supabase_flutter and its Supabase client packages | MIT | https://github.com/supabase/supabase-flutter |
| http, crypto, jni (Dart team packages) | BSD-3-Clause | https://github.com/dart-lang |
| shared_preferences, path_provider, url_launcher, video_player (Flutter team packages) | BSD-3-Clause | https://github.com/flutter/packages |
| package_info_plus | BSD-3-Clause | https://github.com/fluttercommunity/plus_plugins |
| flutter_secure_storage | BSD-3-Clause | https://github.com/mogol/flutter_secure_storage |
| mobile_scanner | BSD-3-Clause | https://github.com/juliansteenbakker/mobile_scanner |
| qr_flutter | BSD-3-Clause | https://github.com/theyakka/qr.flutter |
| cached_network_image | MIT | https://github.com/Baseflow/flutter_cached_network_image |
| file_picker | MIT | https://github.com/vicajilau/flutter_file_picker |
| archive | MIT | https://github.com/brendan-duncan/archive |
| simple_icons | CC0-1.0 | https://github.com/jlnrrg/simple_icons |

## Android and Android TV

| Component | License | Upstream |
|---|---|---|
| libmpv for Android (`full` flavor) | Build scripts MIT. The bundled mpv/FFmpeg libraries follow their own licenses | https://github.com/media-kit/libmpv-android-video-build |
| Stremio Android native streaming libraries (`libstream_server.so`, `libc++_shared.so`) | Being confirmed: the upstream repository has no top-level license file. `libc++` is Apache-2.0 WITH LLVM-exception | https://github.com/stremio-native/stremio-android |
| rustls-platform-verifier (Android AAR) | MIT or Apache-2.0 | https://github.com/rustls/rustls-platform-verifier |

## macOS

macOS packages contain the Flutter engine and the same Dart packages and media_kit/libmpv components listed above, in their macOS builds.

## Corrections

If a notice here is missing or wrong, please open an issue on [GitHub](https://github.com/ish4ra/Orvix/issues).
