import 'package:flutter/material.dart';

import 'models/media_item.dart';
import 'screens/details_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/sources_screen.dart';
import 'services/catalog_service.dart';
import 'services/media_state_service.dart';
import 'services/pikpak_service.dart';
import 'services/pikpak_transfer_service.dart';
import 'services/playback_service.dart';
import 'services/source_provider_service.dart';

class PikoraApp extends StatefulWidget {
  const PikoraApp({super.key});

  @override
  State<PikoraApp> createState() => _PikoraAppState();
}

class _PikoraAppState extends State<PikoraApp> {
  late final CatalogService _catalog;
  late final PikPakService _pikpak;
  late final PikPakTransferService _transfer;
  late final SourceProviderService _sources;
  late final PlaybackService _playback;
  late final MediaStateService _mediaState;

  @override
  void initState() {
    super.initState();
    _catalog = CatalogService();
    _pikpak = PikPakService();
    _transfer = PikPakTransferService();
    _sources = SourceProviderService();
    _playback = PlaybackService();
    _mediaState = MediaStateService();
  }

  @override
  void dispose() {
    _catalog.dispose();
    _pikpak.dispose();
    _transfer.dispose();
    _sources.dispose();
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF795CFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0D1017),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pikora',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF07090E),
        canvasColor: const Color(0xFF090B11),
        dividerColor: const Color(0xFF202431),
        cardTheme: CardThemeData(
          color: const Color(0xFF11141C),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF12151E),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF252A38)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
          ),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF090B11),
          indicatorColor: Color(0xFF282340),
          selectedIconTheme: IconThemeData(color: Color(0xFF9C87FF)),
        ),
      ),
      home: _PikoraShell(
        catalog: _catalog,
        pikpak: _pikpak,
        transfer: _transfer,
        sources: _sources,
        playback: _playback,
        mediaState: _mediaState,
      ),
    );
  }
}

class _PikoraShell extends StatefulWidget {
  const _PikoraShell({
    required this.catalog,
    required this.pikpak,
    required this.transfer,
    required this.sources,
    required this.playback,
    required this.mediaState,
  });

  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final PlaybackService playback;
  final MediaStateService mediaState;

  @override
  State<_PikoraShell> createState() => _PikoraShellState();
}

class _PikoraShellState extends State<_PikoraShell> {
  int _index = 0;
  int _authRevision = 0;
  int _libraryRevision = 0;

  Future<void> _openMedia(MediaItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailsScreen(
          item: item,
          catalog: widget.catalog,
          pikpak: widget.pikpak,
          transfer: widget.transfer,
          sources: widget.sources,
          playback: widget.playback,
          mediaState: widget.mediaState,
        ),
      ),
    );
    if (mounted) setState(() => _libraryRevision++);
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
      SearchScreen(catalog: widget.catalog, onOpen: _openMedia),
      LibraryScreen(
        key: ValueKey(_authRevision),
        pikpak: widget.pikpak,
        transfer: widget.transfer,
        playback: widget.playback,
        onAuthChanged: () => setState(() => _authRevision++),
      ),
      SourcesScreen(sources: widget.sources),
      const _AboutScreen(),
    ];

    final extended = MediaQuery.sizeOf(context).width >= 1180;
    return Scaffold(
      body: Row(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Color(0xFF1B1F2A))),
            ),
            child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              extended: extended,
              minWidth: 78,
              minExtendedWidth: 218,
              groupAlignment: -0.72,
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(10, 22, 10, 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF956CFF), Color(0xFF466CFF)],
                        ),
                        boxShadow: const [
                          BoxShadow(color: Color(0x443F51FF), blurRadius: 22, spreadRadius: 2),
                        ],
                      ),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 27),
                    ),
                    if (extended) ...[
                      const SizedBox(width: 11),
                      const Text(
                        'PIKORA',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.6,
                          fontSize: 18,
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
                  icon: Icon(Icons.cloud_outlined),
                  selectedIcon: Icon(Icons.cloud_rounded),
                  label: Text('My PikPak'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.hub_outlined),
                  selectedIcon: Icon(Icons.hub_rounded),
                  label: Text('Sources'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: Text('About'),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: KeyedSubtree(
                key: ValueKey(_index),
                child: IndexedStack(index: _index, children: screens),
              ),
            ),
          ),
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
                'Pikora v0.3',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              const Text(
                'A PikPak-first cinematic media hub built with Flutter. The Windows build is native Flutter — no Microsoft Edge browser dependency.',
                style: TextStyle(height: 1.55),
              ),
              const SizedBox(height: 24),
              const _FeatureLine(Icons.movie_filter_outlined, 'Cinemeta movie & TV discovery with instant type-ahead search'),
              const _FeatureLine(Icons.cloud_outlined, 'PikPak login, cloud library and cloud-task bridge'),
              const _FeatureLine(Icons.hub_outlined, 'User-configured Stremio-compatible source providers'),
              const _FeatureLine(Icons.play_circle_outline_rounded, 'media_kit / libmpv playback with custom controls and resume'),
              const _FeatureLine(Icons.bookmark_outline_rounded, 'Persistent watchlist and Continue Watching rails'),
              const _FeatureLine(Icons.phone_android_outlined, 'Shared Flutter foundation for future Android & Android TV builds'),
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
