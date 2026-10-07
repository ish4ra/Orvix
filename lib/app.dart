import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/media_item.dart';
import 'screens/account_screen.dart';
import 'screens/details_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/media_library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sources_screen.dart';
import 'screens/supporters_screen.dart';
import 'services/app_update_service.dart';
import 'services/catalog_service.dart';
import 'services/cloud_preferences_service.dart';
import 'services/local_torrent_service.dart';
import 'services/media_state_service.dart';
import 'services/orvix_account_service.dart';
import 'services/pikpak_service.dart';
import 'services/pikpak_transfer_service.dart';
import 'services/playback_service.dart';
import 'services/platform_profile.dart';
import 'services/source_provider_service.dart';
import 'services/torbox_service.dart';
import 'tv/tv_focus.dart';
import 'tv/tv_shell.dart';
import 'tv/tv_theme.dart';
import 'tv/tv_widgets.dart';
import 'widgets/orvix_update_gate.dart';

class OrvixApp extends StatefulWidget {
  const OrvixApp({super.key});

  @override
  State<OrvixApp> createState() => _OrvixAppState();
}

class _OrvixAppState extends State<OrvixApp>
    with WidgetsBindingObserver {
  late final CatalogService _catalog;
  late final PikPakService _pikpak;
  late final PikPakTransferService _transfer;
  late final SourceProviderService _sources;
  late final TorBoxService _torbox;
  late final CloudPreferencesService _cloudPreferences;
  late final PlaybackService _playback;
  late final MediaStateService _mediaState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _catalog = CatalogService();
    _pikpak = PikPakService();
    _transfer = PikPakTransferService();
    _sources = SourceProviderService();
    _torbox = TorBoxService();
    _cloudPreferences = CloudPreferencesService();
    _playback = PlaybackService();
    _mediaState = MediaStateService();
    unawaited(_mediaState.warm());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(LocalTorrentService.instance.dispose());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _catalog.dispose();
    _pikpak.dispose();
    _transfer.dispose();
    _sources.dispose();
    _torbox.dispose();
    LocalTorrentService.instance.dispose();
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB9FF45),
      brightness: Brightness.dark,
      surface: const Color(0xFF0B0F0C),
    ).copyWith(
      primary: const Color(0xFFB9FF45),
      onPrimary: Colors.black,
      primaryContainer: const Color(0xFF263B18),
      onPrimaryContainer: const Color(0xFFE9FFD0),
      secondary: const Color(0xFF9FEA3A),
      onSecondary: Colors.black,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Orvix',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF050806),
        canvasColor: const Color(0xFF070A08),
        dividerColor: const Color(0xFF1B2A1C),
        cardTheme: CardThemeData(
          color: const Color(0xFF0D120E),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        focusColor: const Color(0x66CBFF75),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            textStyle: const TextStyle(
                fontWeight: FontWeight.w900, letterSpacing: .15),
            backgroundColor: const Color(0xFFB9FF45),
            foregroundColor: const Color(0xFF081006),
            elevation: 0,
          ).copyWith(
            side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Colors.white, width: 3);
              }
              return BorderSide.none;
            }),
            elevation: const WidgetStatePropertyAll(0),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFCBFF75),
            side: const BorderSide(color: Color(0xFF426B2E)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
              if (states.contains(WidgetState.focused)) {
                return const Color(0xFF213A1E);
              }
              return Colors.transparent;
            }),
            side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Colors.white, width: 3);
              }
              return const BorderSide(color: Color(0xFF426B2E));
            }),
            elevation: WidgetStateProperty.resolveWith<double?>((states) {
              return states.contains(WidgetState.focused) ? 7 : 0;
            }),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0F1510),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF263627)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
          ),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF070A08),
          indicatorColor: Color(0xFF263B18),
          selectedIconTheme: IconThemeData(
            color: Color(0xFFB9FF45),
            size: 25,
          ),
          unselectedIconTheme: IconThemeData(
            color: Color(0xFF8D9790),
            size: 23,
          ),
          selectedLabelTextStyle: TextStyle(
            color: Color(0xFFEAF5DF),
            fontWeight: FontWeight.w800,
          ),
          unselectedLabelTextStyle: TextStyle(
            color: Color(0xFF8D9790),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: OrvixUpdateGate(
        child: _OrvixShell(
          catalog: _catalog,
          pikpak: _pikpak,
          transfer: _transfer,
          sources: _sources,
          torbox: _torbox,
          cloudPreferences: _cloudPreferences,
          playback: _playback,
          mediaState: _mediaState,
        ),
      ),
    );
  }
}

/// Builds the app shell with injected services, for widget tests.
@visibleForTesting
Widget debugBuildOrvixShell({
  required CatalogService catalog,
  required PikPakService pikpak,
  required PikPakTransferService transfer,
  required SourceProviderService sources,
  required TorBoxService torbox,
  required CloudPreferencesService cloudPreferences,
  required PlaybackService playback,
  required MediaStateService mediaState,
}) =>
    _OrvixShell(
      catalog: catalog,
      pikpak: pikpak,
      transfer: transfer,
      sources: sources,
      torbox: torbox,
      cloudPreferences: cloudPreferences,
      playback: playback,
      mediaState: mediaState,
    );

class _OrvixShell extends StatefulWidget {
  const _OrvixShell({
    required this.catalog,
    required this.pikpak,
    required this.transfer,
    required this.sources,
    required this.torbox,
    required this.cloudPreferences,
    required this.playback,
    required this.mediaState,
  });

  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final TorBoxService torbox;
  final CloudPreferencesService cloudPreferences;
  final PlaybackService playback;
  final MediaStateService mediaState;

  @override
  State<_OrvixShell> createState() => _OrvixShellState();
}

class _OrvixShellState extends State<_OrvixShell> {
  int _index = 0;
  int _authRevision = 0;
  int _libraryRevision = 0;

  void _refreshAfterAccountChange() {
    if (!mounted) return;
    setState(() {
      _authRevision++;
      _libraryRevision++;
    });
  }

  Future<void> _openMedia(MediaItem item) async {
    final warmItem = widget.catalog.peekDetails(item) ?? item;
    unawaited(widget.catalog.prefetchDetails(item));

    EpisodeItem? warmEpisode;
    if (warmItem.kind == MediaKind.series && warmItem.episodes.isNotEmpty) {
      final ordered = [...warmItem.episodes]
        ..sort((a, b) {
          final bySeason = a.season.compareTo(b.season);
          return bySeason != 0 ? bySeason : a.episode.compareTo(b.episode);
        });
      warmEpisode = ordered.first;
    }
    if (warmItem.kind == MediaKind.movie || warmEpisode != null) {
      unawaited(widget.sources.prefetch(warmItem, episode: warmEpisode));
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailsScreen(
          item: warmItem,
          catalog: widget.catalog,
          pikpak: widget.pikpak,
          transfer: widget.transfer,
          sources: widget.sources,
          torbox: widget.torbox,
          cloudPreferences: widget.cloudPreferences,
          playback: widget.playback,
          mediaState: widget.mediaState,
        ),
      ),
    );
    try {
      await OrvixAccountService.pushLocalStateIfSignedIn();
    } catch (_) {}
    if (mounted) setState(() => _libraryRevision++);
  }

  Future<void> _resumeContinueWatching(ContinueWatchingEntry entry) async {
    final rich = await widget.catalog.details(entry.item) ?? entry.item;
    if (!mounted) return;

    final key = GlobalKey<_ContinueResumeHostState>();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ContinueResumeHost(
          key: key,
          item: rich,
          episode: entry.episode,
          catalog: widget.catalog,
          pikpak: widget.pikpak,
          transfer: widget.transfer,
          sources: widget.sources,
          torbox: widget.torbox,
          cloudPreferences: widget.cloudPreferences,
          playback: widget.playback,
          mediaState: widget.mediaState,
        ),
      ),
    );
    if (mounted) setState(() => _libraryRevision++);
  }

  void _selectDestination(int value) {
    setState(() => _index = value);
    OrvixAccountService.pushLocalStateIfSignedIn().catchError((_) {});
  }

  Future<void> _showCompactMoreMenu() async {
    final value = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF0D120E),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.cloud_rounded),
                title: const Text('Clouds'),
                onTap: () => Navigator.pop(sheetContext, 3),
              ),
              ListTile(
                leading: const Icon(Icons.settings_rounded),
                title: const Text('Settings'),
                onTap: () => Navigator.pop(sheetContext, 5),
              ),
              ListTile(
                leading: const Icon(Icons.person_rounded),
                title: const Text('Account'),
                onTap: () => Navigator.pop(sheetContext, 6),
              ),
              ListTile(
                leading: const Icon(Icons.favorite_rounded),
                title: const Text('Support'),
                onTap: () => Navigator.pop(sheetContext, 7),
              ),
              ListTile(
                leading: const Icon(Icons.info_rounded),
                title: const Text('About'),
                onTap: () => Navigator.pop(sheetContext, 8),
              ),
            ],
          ),
        ),
      ),
    );
    if (value != null) _selectDestination(value);
  }

  int get _compactNavigationIndex {
    switch (_index) {
      case 0:
        return 0;
      case 1:
        return 1;
      case 2:
        return 2;
      case 4:
        return 3;
      default:
        return 4;
    }
  }

  static const _tvDestinations = <TvDestination>[
    TvDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
    ),
    TvDestination(
      icon: Icons.search_rounded,
      selectedIcon: Icons.manage_search_rounded,
      label: 'Search',
    ),
    TvDestination(
      icon: Icons.video_library_outlined,
      selectedIcon: Icons.video_library_rounded,
      label: 'Library',
    ),
    TvDestination(
      icon: Icons.cloud_outlined,
      selectedIcon: Icons.cloud_rounded,
      label: 'Clouds',
    ),
    TvDestination(
      icon: Icons.hub_outlined,
      selectedIcon: Icons.hub_rounded,
      label: 'Sources',
    ),
    TvDestination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
    ),
    TvDestination(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Account',
    ),
    TvDestination(
      icon: Icons.favorite_border_rounded,
      selectedIcon: Icons.favorite_rounded,
      label: 'Support',
    ),
    TvDestination(
      icon: Icons.info_outline_rounded,
      selectedIcon: Icons.info_rounded,
      label: 'About',
    ),
  ];

  /// Android TV destinations. Built only once visited (see TvShell), so the
  /// Account QR login only runs while Account is open.
  Widget _tvScreen(int index) {
    switch (index) {
      case 0:
        return HomeScreen(
          catalog: widget.catalog,
          sources: widget.sources,
          mediaState: widget.mediaState,
          onOpen: _openMedia,
          onResume: _resumeContinueWatching,
        );
      case 1:
        return SearchScreen(
          catalog: widget.catalog,
          sources: widget.sources,
          onOpen: _openMedia,
          active: _index == 1,
        );
      case 2:
        return MediaLibraryScreen(
          key: ValueKey('media-library-$_libraryRevision'),
          mediaState: widget.mediaState,
          onOpen: _openMedia,
        );
      case 3:
        // Rebuilt after an Orvix account change, which can bring synced
        // provider credentials; a provider connecting from inside Clouds
        // must not rebuild the screen under the remote.
        return LibraryScreen(
          key: ValueKey(_authRevision),
          pikpak: widget.pikpak,
          transfer: widget.transfer,
          torbox: widget.torbox,
          cloudPreferences: widget.cloudPreferences,
          playback: widget.playback,
          onAuthChanged: () {},
        );
      case 4:
        return SourcesScreen(sources: widget.sources);
      case 5:
        return const SettingsScreen();
      case 6:
        return AccountScreen(
          active: _index == 6,
          onAuthChanged: _refreshAfterAccountChange,
        );
      case 7:
        return const SupportersScreen();
      default:
        return const _AboutScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) {
      return TvShell(
        destinations: _tvDestinations,
        selectedIndex: _index,
        onSelected: _selectDestination,
        brand: (expanded) => Padding(
          padding: const EdgeInsets.only(left: 18),
          child: _OrvixBrand(
            iconSize: 44,
            fontSize: 22,
            showWordmark: expanded,
          ),
        ),
        screenBuilder: (context, index) => _tvScreen(index),
      );
    }

    final screens = <Widget>[
      HomeScreen(
        // Keep the Home element/state alive when returning from Details.
        // Library revisions still rebuild this shell, but must not remount Home:
        // remounting recreates its Future/ListView and jumps the user to the top.
        catalog: widget.catalog,
        sources: widget.sources,
        mediaState: widget.mediaState,
        onOpen: _openMedia,
        onResume: _resumeContinueWatching,
      ),
      SearchScreen(
        catalog: widget.catalog,
        sources: widget.sources,
        onOpen: _openMedia,
        active: _index == 1,
      ),
      MediaLibraryScreen(
        key: ValueKey('media-library-$_libraryRevision'),
        mediaState: widget.mediaState,
        onOpen: _openMedia,
      ),
      LibraryScreen(
        key: ValueKey(_authRevision),
        pikpak: widget.pikpak,
        transfer: widget.transfer,
        torbox: widget.torbox,
        cloudPreferences: widget.cloudPreferences,
        playback: widget.playback,
        onAuthChanged: () => setState(() => _authRevision++),
      ),
      SourcesScreen(sources: widget.sources),
      const SettingsScreen(),
      AccountScreen(
        key: ValueKey('account-$_authRevision'),
        onAuthChanged: _refreshAfterAccountChange,
      ),
      const SupportersScreen(),
      const _AboutScreen(),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 720;
    final extended = width >= 1180;
    final windowsDesktop = Platform.isWindows && !compact;
    final railExtended = extended && !windowsDesktop;

    // One IndexedStack that is never re-keyed: every destination keeps its
    // State (Home's loaded catalog and scroll position, Search's query and
    // results) across navigation. Keying it by the selected index used to
    // remount all destinations on every switch, so Home reloaded its catalog.
    Widget body = _DestinationFade(
      index: _index,
      child: IndexedStack(index: _index, children: screens),
    );

    if (compact) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _compactNavigationIndex,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (value) {
            switch (value) {
              case 0:
                _selectDestination(0);
                break;
              case 1:
                _selectDestination(1);
                break;
              case 2:
                _selectDestination(2);
                break;
              case 3:
                _selectDestination(4);
                break;
              default:
                _showCompactMoreMenu();
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.search_rounded),
              selectedIcon: Icon(Icons.manage_search_rounded),
              label: 'Search',
            ),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library_rounded),
              label: 'Library',
            ),
            NavigationDestination(
              icon: Icon(Icons.hub_outlined),
              selectedIcon: Icon(Icons.hub_rounded),
              label: 'Sources',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz_rounded),
              selectedIcon: Icon(Icons.more_rounded),
              label: 'More',
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Color(0xFF18251A))),
            ),
            child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _selectDestination,
              extended: railExtended,
              minWidth: windowsDesktop ? 72 : 86,
              minExtendedWidth: 226,
              groupAlignment: -0.72,
              leading: Padding(
                padding: EdgeInsets.fromLTRB(
                  windowsDesktop ? 10 : 7,
                  windowsDesktop ? 14 : 18,
                  windowsDesktop ? 10 : 7,
                  windowsDesktop ? 24 : 28,
                ),
                child: _OrvixBrand(
                  iconSize: windowsDesktop ? 48 : 72,
                  fontSize: 20,
                  showWordmark: railExtended,
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: Text('Home'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.search_rounded),
                  selectedIcon: Icon(Icons.manage_search_rounded),
                  label: Text('Search'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: Text('Library'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.cloud_outlined),
                  selectedIcon: Icon(Icons.cloud_rounded),
                  label: Text('Clouds'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.hub_outlined),
                  selectedIcon: Icon(Icons.hub_rounded),
                  label: Text('Sources'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: Text('Settings'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: Text('Account'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.favorite_border_rounded),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: Text('Support'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.info_outline_rounded),
                  selectedIcon: Icon(Icons.info_rounded),
                  label: Text('About'),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Short fade-in when the selected destination changes. It animates opacity
/// only and never changes the child's identity, so no destination remounts.
class _DestinationFade extends StatefulWidget {
  const _DestinationFade({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_DestinationFade> createState() => _DestinationFadeState();
}

class _DestinationFadeState extends State<_DestinationFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  @override
  void didUpdateWidget(covariant _DestinationFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

class _ContinueResumeHost extends StatefulWidget {
  const _ContinueResumeHost({
    super.key,
    required this.item,
    required this.episode,
    required this.catalog,
    required this.pikpak,
    required this.transfer,
    required this.sources,
    required this.torbox,
    required this.cloudPreferences,
    required this.playback,
    required this.mediaState,
  });
  final MediaItem item;
  final EpisodeItem? episode;
  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final TorBoxService torbox;
  final CloudPreferencesService cloudPreferences;
  final PlaybackService playback;
  final MediaStateService mediaState;
  @override State<_ContinueResumeHost> createState() => _ContinueResumeHostState();
}

class _ContinueResumeHostState extends State<_ContinueResumeHost> {
  final _detailsKey = GlobalKey<DetailsScreenState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _detailsKey.currentState?.resumeContinueWatching(widget.item, widget.episode);
      if (mounted) Navigator.of(context).pop();
    });
  }
  @override
  Widget build(BuildContext context) => DetailsScreen(
    key: _detailsKey,
    item: widget.item,
    catalog: widget.catalog,
    pikpak: widget.pikpak,
    transfer: widget.transfer,
    sources: widget.sources,
    torbox: widget.torbox,
    cloudPreferences: widget.cloudPreferences,
    playback: widget.playback,
    mediaState: widget.mediaState,
  );
}


class _OrvixBrand extends StatelessWidget {
  const _OrvixBrand({
    required this.iconSize,
    required this.fontSize,
    required this.showWordmark,
  });

  final double iconSize;
  final double fontSize;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: iconSize,
          height: iconSize,
          child: Image.asset(
            'assets/branding/orvix_logo.webp',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => Icon(
              Icons.play_circle_fill_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: iconSize,
            ),
          ),
        ),
        if (showWordmark) ...[
          SizedBox(width: iconSize * .20),
          Text(
            'orvix',
            style: TextStyle(
              color: const Color(0xFFEEFFD3),
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: -fontSize * .025,
              height: 1,
            ),
          ),
        ],
      ],
    );
  }
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  static const _features = <(IconData, String)>[
    (Icons.movie_filter_outlined,
        'Rich movie & TV discovery with AIOMetadata/Cinemeta fallback'),
    (Icons.cloud_outlined,
        'Debrid and cloud-service connections, libraries and transfer bridge'),
    (Icons.person_outline_rounded,
        'Optional Orvix account for Library, progress and preference sync'),
    (Icons.hub_outlined, 'User-configured Stremio-compatible source providers'),
    (Icons.hub_rounded,
        'Built-in local BitTorrent/P2P streaming on Windows, Android mobile, Android TV and macOS when no debrid account is connected'),
    (Icons.play_circle_outline_rounded,
        'Dual-engine Android playback: Auto / ExoPlayer / MPV, with libmpv on desktop and shared custom controls'),
    (Icons.subtitles_rounded,
        'OpenSubtitles v3 online subtitle addon with language filtering, sync and appearance controls'),
    (Icons.video_library_outlined,
        'Personal Library, persistent watchlist, and multi-title Continue Watching'),
    (Icons.dashboard_customize_outlined,
        'Customizable Home rows including optional IMDb Top 250 shelves'),
    (Icons.phone_android_outlined,
        'Shared Orvix feature set and branding across Windows, Android mobile, Android TV and macOS'),
  ];

  static Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  Widget _buildTv(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.pageHorizontal,
        TvMetrics.pageTop,
        TvMetrics.pageHorizontal,
        TvMetrics.pageBottom,
      ),
      children: [
        const _OrvixBrand(iconSize: 60, fontSize: 34, showWordmark: true),
        const SizedBox(height: 20),
        FutureBuilder<String>(
          future: AppUpdateService.installedVersion(),
          builder: (context, snapshot) {
            final version = snapshot.data?.trim();
            return Text(
              version == null || version.isEmpty ? 'Orvix' : 'Orvix v$version',
              style: TvText.title,
            );
          },
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: const Text(
            'A multi-cloud cinematic media hub built with Flutter. Orvix connects your cloud services, source providers, library and player across desktop, mobile and TV.',
            style: TvText.body,
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            TvButton(
              kind: TvButtonKind.primary,
              icon: Icons.language_rounded,
              label: 'isharalakshan.xyz',
              preferred: true,
              onPressed: () => _open('https://isharalakshan.xyz/orvix/'),
            ),
            TvButton(
              icon: SimpleIcons.mastodon,
              label: 'Mastodon',
              onPressed: () => _open('https://fosstodon.org/@orvix'),
            ),
            TvButton(
              icon: SimpleIcons.lemmy,
              label: 'Lemmy',
              onPressed: () => _open('https://lemmy.ml/c/Orvix'),
            ),
            TvButton(
              icon: SimpleIcons.github,
              label: 'GitHub',
              onPressed: () => _open('https://github.com/ish4ra/Orvix'),
            ),
          ],
        ),
        const SizedBox(height: 30),
        const TvSectionHeader('What Orvix includes'),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: TvFocusable(
            semanticLabel: 'What Orvix includes',
            builder: (context, focused) => AnimatedContainer(
              duration: TvMetrics.focusDuration,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: focused ? TvColors.cardFocused : TvColors.surface,
                borderRadius: BorderRadius.circular(TvMetrics.radius),
                border: Border.all(
                  color: focused ? TvColors.primary : TvColors.border,
                  width: focused ? TvMetrics.focusBorder : 1,
                ),
              ),
              child: Column(
                children: [
                  for (final (icon, text) in _features)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(icon, size: 21, color: TvColors.primary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              text,
                              style: TvText.body.copyWith(
                                  color: const Color(0xFFD5DDD4)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) return _buildTv(context);
    return ListView(
      padding: const EdgeInsets.all(34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _OrvixBrand(
                iconSize: 68,
                fontSize: 38,
                showWordmark: true,
              ),
              const SizedBox(height: 26),
              FutureBuilder<String>(
                future: AppUpdateService.installedVersion(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.trim();
                  return Text(
                    version == null || version.isEmpty
                        ? 'Orvix'
                        : 'Orvix v$version',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w900),
                  );
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'A multi-cloud cinematic media hub built with Flutter. Orvix connects your cloud services, source providers, library and player across desktop, mobile and TV.',
                style: TextStyle(height: 1.55),
              ),
              const SizedBox(height: 18),
              const _SupportButton(
                icon: Icons.language_rounded,
                label: 'isharalakshan.xyz',
                url: 'https://isharalakshan.xyz/orvix/',
              ),
              const SizedBox(height: 28),
              Text(
                'Community',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text(
                'Follow Orvix updates and join the community.',
                style: TextStyle(color: Color(0xFF9EAAA0), height: 1.45),
              ),
              const SizedBox(height: 16),
              const Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _SupportButton(
                    icon: SimpleIcons.mastodon,
                    label: 'Mastodon',
                    url: 'https://fosstodon.org/@orvix',
                  ),
                  _SupportButton(
                    icon: SimpleIcons.lemmy,
                    label: 'Lemmy',
                    url: 'https://lemmy.ml/c/Orvix',
                  ),
                  _SupportButton(
                    icon: SimpleIcons.github,
                    label: 'GitHub',
                    url: 'https://github.com/ish4ra/Orvix',
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Text(
                'What Orvix includes',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              for (final (icon, text) in _features) _FeatureLine(icon, text),
            ],
          ),
        ),
      ],
    );
  }
}

class _SupportButton extends StatelessWidget {
  const _SupportButton({
    required this.label,
    required this.url,
    required this.icon,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final String url;
  final bool primary;

  Future<void> _open() async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _buttonIcon() => Icon(icon, size: 19);

  @override
  Widget build(BuildContext context) {
    if (primary) {
      return FilledButton.icon(
        onPressed: _open,
        icon: _buttonIcon(),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: _open,
      icon: _buttonIcon(),
      label: Text(label),
    );
  }
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
