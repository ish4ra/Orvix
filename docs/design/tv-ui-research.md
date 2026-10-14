# Android TV source picker and player: research and design direction

This is the research behind the v0.7.10-beta.3 redesign of three Android TV
surfaces: the source picker, the ExoPlayer controls and the buffering
indicator. Screenshots before and after are in `tv-beta3/`. They were made
by the real-font tests (`test/tv_source_picker_visual_test.dart` and
`test/tv_player_visual_test.dart`) with `ORVIX_CAPTURE_DIR` set. Those tests
use no video, so the picture is black.

## 1. What was examined

Only the source code of open-source apps was read, and none of it was
copied. All of these apps are GPL-2.0, GPL-3.0 or CC BY-SA, so only design
principles are reused.

- **NuvioTV**, https://github.com/tapframe/NuvioTV (GPL-3.0), files under
  `app/src/main/java/com/nuvio/tv/ui/`:
  - `screens/player/PlayerScreen.kt`
  - `PlayerOverlayScaffold.kt`, `LoadingOverlay.kt`
  - `StreamSourcesSidePanel.kt`, `SubtitleStyleSidePanel.kt`
  - `screens/stream/StreamScreen.kt`
  - `components/StreamBadgeChips.kt`, `SourceStatusFilterChip.kt`
  - `theme/SpacingTokens.kt`
  - `data/local/PlayerSettingsDataStore.kt`
- **NuvioMobile**, https://github.com/tapframe/NuvioStreaming (GPL-3.0),
  files under `composeApp/.../features/`:
  - `player/PlayerControls.kt`, `PlayerLayout.kt`, `SubtitleStylePanel.kt`
  - `PlayerLoadingStatus.kt`
  - `streams/StreamCard.kt`
- **Jellyfin Android TV**, https://github.com/jellyfin/jellyfin-androidtv
  (GPL-2.0):
  - `ui/player/base/PlayerOverlayLayout.kt`, `PlayerSeekbar.kt`
  - `ui/player/video/VideoPlayerControls.kt`, `VideoPlayerHeader.kt`
  - `ui/base/button/IconButton.kt`
  - `ui/composable/modifier/overscan.kt`
  - `preference/UserPreferences.kt`
- **Kodi Estuary skin**, https://github.com/xbmc/xbmc (skin CC BY-SA 4.0
  and GPL-2.0):
  - `addons/skin.estuary/xml/VideoOSD.xml`, `DialogSeekBar.xml`,
    `DialogBusy.xml`, `VideoFullScreen.xml`
  - `system/settings/settings.xml` (subtitle settings)
- **Netflix on TV.** No source code was seen; none is public. Only publicly
  reported behaviour was used: the title at the top, a thin scrubber, a few
  primary controls, and secondary text buttons such as *Audio & Subtitles*
  and *Next Episode*.

## 2. Useful patterns

- **Gradient scrims instead of blur.** Each app darkens the top and bottom
  thirds with linear gradients. NuvioTV enables blur only on API 31 and
  above, and Jellyfin and Kodi never blur. A live blur is costly on low-end
  TV GPUs.
- **Overscan-safe padding,** about 48 dp horizontal and 27–32 dp vertical
  (Jellyfin `overscan.kt`).
- **Colour-swap focus states.** Jellyfin fills the focused button light and
  draws its icon dark, with no scale. On dense lists, a scale of 1.0–1.05 at
  most (NuvioTV `focusedScale`).
- **Focus restoration by stable item key,** not by index, when a list
  re-orders. Orvix already does this with `findChildIndexCallback`.
- **Few primary controls plus labelled secondary tools.** NuvioMobile uses
  labelled pills; Netflix uses secondary text buttons.
- **Buffering has two states:** a startup loader with a stage message, and
  a small rebuffer indicator. Kodi fades its cache ring in only after
  300 ms, which avoids flicker. Showing data that really arrived (Kodi's
  cache level, NuvioTV's torrent stats) is better than a bare spinner.
- **Subtitle style in a side sheet with a live preview.** Steppers and
  swatches rather than sliders, every setting persisted on its own, and a
  Reset. The common setting set across the apps is size, colour, opacity,
  outline, background, position and a 100 ms delay step.
- **Provider filters that carry a count or a status** (NuvioTV
  `SourceStatusFilterChip`).

## 3. Rejected, and why

- **Real-time blur** (Haze or `BackdropFilter`): too slow on the hardware
  Orvix targets.
- **Marquee badge rows and pulsing chips:** they repaint all the time and
  pull attention away from the focused item.
- **Thirteen-plus icon-only buttons in one row** (NuvioTV): hard to read
  from a sofa. Orvix keeps labels on its tools.
- **Kodi's invisible full-screen "close" button:** it suits a pointer, and
  becomes a focus trap with a D-pad. The redesign also removes Orvix's own
  equivalent: the video surface no longer takes part in D-pad traversal.
- **Native popup menus for tracks** (legacy Jellyfin): they cannot be
  focus-styled consistently.
- **Copying any layout values, assets or code.** Everything here is written
  for Orvix.

## 4. The Orvix TV direction

These rules apply to all three surfaces.

- **Lime means selected or primary, never "focused".** Focus is a white fill
  with dark content: picker controls, provider tabs, player tools and menu
  rows. The two exceptions are Play/Pause, which turns lime when focused,
  and source cards, which get a lime border when focused. Selected modes
  and tracks are lime.
- **One strong control per surface.**
  - In the picker it is the focused source card: a lime border and a lime
    play disc.
  - In the player it is Play/Pause: white, or lime when focused, and 58 dp
    across.
- **Quiet everything else.** Tools are borderless until focused. Icon-only
  actions (Settings, MPV) show a floating label when focused, so no
  neighbour shifts.
- **Information as structure, not as a sentence.**
  - The picker shows a resolution tile (4K filled, 1080p outlined) with the
    release type, the release name, and icon facts. The emoji stats line
    that repeated the same facts is gone from TV.
  - The Free P2P status keeps its label and reason.
  - Recommended sources carry a lime edge.
- **Honest states.**
  - The count capsule says "12 of 61 sources" when filters hide some.
  - An empty filter result offers "Show all sources".
  - Buffering stays invisible for 400 ms, then shows a ring. After the slow
    notice it says "Waiting for peers…" only while no new data arrives;
    otherwise it says how much did arrive.
  - There is no deadline.
- **Cheap to draw.**
  - The picker draws one decoded backdrop under fixed gradients.
  - There are no shadows, glows or blur.
  - Focus animations last 120–130 ms.

## 5. Kept exactly as before

Everything below works as it did before the redesign:
- source ranking, the live check, pinning (Hold OK), filters, priority order
  and the help text;
- every player control, menu, key binding, subtitle style option, timing,
  diagnostics, Try MPV and the patient P2P startup;
- the phone ExoPlayer layout and the MPV player.
