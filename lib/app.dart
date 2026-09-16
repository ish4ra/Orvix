import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'services/catalog_service.dart';
import 'services/pikpak_service.dart';

class PikoraApp extends StatefulWidget {
  const PikoraApp({super.key});

  @override
  State<PikoraApp> createState() => _PikoraAppState();
}

class _PikoraAppState extends State<PikoraApp> {
  late final CatalogService _catalog;
  late final PikPakService _pikpak;

  @override
  void initState() {
    super.initState();
    _catalog = CatalogService();
    _pikpak = PikPakService();
  }

  @override
  void dispose() {
    _catalog.dispose();
    _pikpak.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF765BFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0C0E14),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pikora',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF08090D),
        cardTheme: const CardThemeData(
          color: Color(0xFF11141C),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF12151E),
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
            borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
          ),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF0A0C11),
          indicatorColor: Color(0xFF27233E),
        ),
      ),
      home: _PikoraShell(catalog: _catalog, pikpak: _pikpak),
    );
  }
}

class _PikoraShell extends StatefulWidget {
  const _PikoraShell({required this.catalog, required this.pikpak});

  final CatalogService catalog;
  final PikPakService pikpak;

  @override
  State<_PikoraShell> createState() => _PikoraShellState();
}

class _PikoraShellState extends State<_PikoraShell> {
  int _index = 0;
  int _authRevision = 0;

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      HomeScreen(catalog: widget.catalog),
      SearchScreen(catalog: widget.catalog),
      LibraryScreen(
        key: ValueKey(_authRevision),
        pikpak: widget.pikpak,
        onAuthChanged: () => setState(() => _authRevision++),
      ),
      const _AboutScreen(),
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            extended: MediaQuery.sizeOf(context).width >= 1160,
            minExtendedWidth: 210,
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(8, 20, 8, 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF815CFF), Color(0xFF3D8DFF)],
                      ),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                  ),
                  if (MediaQuery.sizeOf(context).width >= 1160) ...[
                    const SizedBox(width: 10),
                    const Text(
                      'PIKORA',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
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
                selectedIcon: Icon(Icons.home),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.search),
                selectedIcon: Icon(Icons.manage_search),
                label: Text('Search'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.cloud_outlined),
                selectedIcon: Icon(Icons.cloud),
                label: Text('My PikPak'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.info_outline),
                selectedIcon: Icon(Icons.info),
                label: Text('About'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(index: _index, children: screens),
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
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pikora v0.3',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 14),
              const Text(
                'A PikPak-first media hub. This Flutter branch removes the old Edge executable dependency and is the foundation for Windows now and Android/Android TV later.',
                style: TextStyle(height: 1.55),
              ),
              const SizedBox(height: 18),
              const Text(
                'Current focus: catalog browsing, instant search suggestions, reliable PikPak authentication, cloud library browsing, and then built-in playback.',
                style: TextStyle(height: 1.55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
