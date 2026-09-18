import 'package:flutter/material.dart';

import 'models/media_item.dart';
import 'screens/account_screen.dart';
import 'screens/details_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/media_library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sources_screen.dart';
import 'services/catalog_service.dart';
import 'services/cloud_preferences_service.dart';
import 'services/local_torrent_service.dart';
import 'services/media_state_service.dart';
import 'services/orvix_account_service.dart';
import 'services/pikpak_service.dart';
import 'services/pikpak_transfer_service.dart';
import 'services/playback_service.dart';
import 'services/source_provider_service.dart';
import 'services/torbox_service.dart';

class OrvixApp extends StatefulWidget {
  const OrvixApp({super.key});

  @override
  State<OrvixApp> createState() => _OrvixAppState();
}

class _OrvixAppState extends State<OrvixApp> {
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
    _catalog = CatalogService();
    _pikpak = PikPakService();
    _transfer = PikPakTransferService();
    _sources = SourceProviderService();
    _torbox = TorBoxService();
    _cloudPreferences = CloudPreferencesService();
    _playback = PlaybackService();
    _mediaState = MediaStateService();
  }

  @override
  void dispose() {
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
            shadowColor: const Color(0x993CFF00),
            elevation: 2,
          ).copyWith(
            side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Colors.white, width: 3);
              }
              return BorderSide.none;
            }),
            elevation: WidgetStateProperty.resolveWith<double?>((states) {
              return states.contains(WidgetState.focused) ? 9 : 2;
            }),
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
          indicatorColor: Color(0xFF172416),
          selectedIconTheme: IconThemeData(color: Color(0xFFCBFF75)),
        ),
      ),
      home: _OrvixShell(
        catalog: _catalog,
        pikpak: _pikpak,
        transfer: _transfer,
        sources: _sources,
        torbox: _torbox,
        cloudPreferences: _cloudPreferences,
        playback: _playback,
        mediaState: _mediaState,
      ),
    );
  }
}

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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailsScreen(
          item: item,
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
                leading: const Icon(Icons.info_rounded),
                title: const Text('About'),
                onTap: () => Navigator.pop(sheetContext, 7),
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

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      HomeScreen(
        key: ValueKey(_libraryRevision),
        catalog: widget.catalog,
        mediaState: widget.mediaState,
        onOpen: _openMedia,
      ),
      SearchScreen(
        catalog: widget.catalog,
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
      const _AboutScreen(),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 720;
    final extended = width >= 1180;

    Widget body = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: KeyedSubtree(
        key: ValueKey(_index),
        child: IndexedStack(index: _index, children: screens),
      ),
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
              extended: extended,
              minWidth: 86,
              minExtendedWidth: 226,
              groupAlignment: -0.72,
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(7, 18, 7, 28),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: Image.asset(
                        'assets/branding/orvix_icon.png',
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Color(0xFFB9FF45),
                            size: 42,
                          ),
                        ),
                      ),
                    ),
                    if (extended) ...[
                      const SizedBox(width: 11),
                      const Text(
                        'ORVIX',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.1,
                          fontSize: 20,
                        ),
                      ),
                    ],
                  ],
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

class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Orvix v0.7.4-alpha.05',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              const Text(
                'A multi-cloud cinematic media hub built with Flutter. Orvix connects your cloud services, source providers, library and player across desktop, mobile and TV.',
                style: TextStyle(height: 1.55),
              ),
              const SizedBox(height: 24),
              const _FeatureLine(Icons.movie_filter_outlined,
                  'Rich movie & TV discovery with AIOMetadata/Cinemeta fallback'),
              const _FeatureLine(Icons.cloud_outlined,
                  'PikPak + TorBox cloud connections, cloud libraries and transfer bridge'),
              const _FeatureLine(Icons.person_outline_rounded,
                  'Optional Orvix account for Library, progress and preference sync'),
              const _FeatureLine(Icons.hub_outlined,
                  'User-configured Stremio-compatible source providers'),
              const _FeatureLine(Icons.hub_rounded,
                  'Built-in local BitTorrent/P2P streaming on Windows, Android mobile, Android TV and macOS when no debrid account is connected'),
              const _FeatureLine(Icons.play_circle_outline_rounded,
                  'media_kit / libmpv playback with custom controls and resume'),
              const _FeatureLine(Icons.subtitles_rounded,
                  'OpenSubtitles v3 online subtitle addon with language filtering, sync and appearance controls'),
              const _FeatureLine(Icons.video_library_outlined,
                  'Personal Library, persistent watchlist, and multi-title Continue Watching'),
              const _FeatureLine(Icons.dashboard_customize_outlined,
                  'Customizable Home rows including optional IMDb Top 250 shelves'),
              const _FeatureLine(Icons.phone_android_outlined,
                  'Shared Orvix feature set and branding across Windows, Android mobile, Android TV and macOS'),
            ],
          ),
        ),
      ],
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
