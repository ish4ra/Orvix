import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/platform_profile.dart';
import '../services/supporters_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';

class SupportersScreen extends StatefulWidget {
  const SupportersScreen({super.key});
  @override
  State<SupportersScreen> createState() => _SupportersScreenState();
}

class _SupportersScreenState extends State<SupportersScreen>
    with SingleTickerProviderStateMixin {
  late Future<List<OrvixSupporter>> _supporters;
  late Future<List<OrvixContributor>> _contributors;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _reload() {
    _supporters = SupportersService.fetchPublicSupporters();
    _contributors = SupportersService.fetchContributors();
  }

  Future<void> _open(String? value) async {
    if (value == null || value.isEmpty) return;
    await launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication);
  }

  bool _tvContributors = false;

  Widget _buildTv(BuildContext context) {
    const links = [
      ('GitHub Sponsors', 'https://github.com/sponsors/ish4ra', SimpleIcons.githubsponsors),
      ('Buy Me a Coffee', 'https://buymeacoffee.com/ish4ra', SimpleIcons.buymeacoffee),
      ('Ko-fi', 'https://ko-fi.com/ish4ra', SimpleIcons.kofi),
      ('Star on GitHub', 'https://github.com/ish4ra/Orvix', SimpleIcons.github),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.pageHorizontal,
        TvMetrics.pageTop,
        TvMetrics.pageHorizontal,
        TvMetrics.pageBottom,
      ),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TvPageHeader(
                  title: 'Support Orvix',
                  subtitle:
                      'Orvix is free and open source. Support development, meet the earliest supporters, and see the contributors building the project.',
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final (label, url, icon) in links)
                      TvButton(
                        kind: label == 'GitHub Sponsors'
                            ? TvButtonKind.primary
                            : TvButtonKind.secondary,
                        preferred: label == 'GitHub Sponsors',
                        icon: icon,
                        label: label,
                        onPressed: () => _open(url),
                      ),
                  ],
                ),
                const SizedBox(height: 28),
                TvTabGroup(
                  child: Wrap(
                  spacing: 12,
                  children: [
                    TvTab(
                      key: const ValueKey('tv-support-supporters'),
                      label: 'Supporters',
                      icon: Icons.favorite_rounded,
                      selected: !_tvContributors,
                      onPressed: () => setState(() => _tvContributors = false),
                    ),
                    TvTab(
                      key: const ValueKey('tv-support-contributors'),
                      label: 'Contributors',
                      icon: Icons.groups_rounded,
                      selected: _tvContributors,
                      onPressed: () => setState(() => _tvContributors = true),
                    ),
                  ],
                ),
                ),
                const SizedBox(height: 16),
                if (_tvContributors)
                  FutureBuilder<List<OrvixContributor>>(
                    future: _contributors,
                    builder: (context, snap) => _tvList<OrvixContributor>(
                      snap,
                      empty: 'GitHub contributors will appear here.',
                      failed: 'Could not load contributors.',
                      row: (c, i) => TvListRow(
                        icon: Icons.person_rounded,
                        leading: _Avatar(url: c.avatarUrl, fallback: c.login),
                        title: c.login,
                        subtitle:
                            '${c.contributions} contribution${c.contributions == 1 ? '' : 's'}',
                        trailingIcon: Icons.open_in_new_rounded,
                        onPressed: () => _open(c.profileUrl),
                      ),
                    ),
                  )
                else
                  FutureBuilder<List<OrvixSupporter>>(
                    future: _supporters,
                    builder: (context, snap) => _tvList<OrvixSupporter>(
                      snap,
                      empty: 'The first public supporters will be recognized here.',
                      failed: 'Could not load supporters.',
                      row: (s, i) => TvListRow(
                        icon: Icons.favorite_rounded,
                        leading: _Avatar(url: s.avatarUrl, fallback: s.name),
                        title: i < 3 ? '${s.name}   #${i + 1}' : s.name,
                        subtitle: [
                          s.providerLabel,
                          s.supportType,
                          if (s.tier?.isNotEmpty == true) s.tier!,
                        ].join(' • '),
                        trailingIcon:
                            s.profileUrl == null ? null : Icons.open_in_new_rounded,
                        onPressed: () => _open(s.profileUrl),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tvList<T>(
    AsyncSnapshot<List<T>> snap, {
    required String empty,
    required String failed,
    required Widget Function(T item, int index) row,
  }) {
    if (snap.connectionState != ConnectionState.done) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (snap.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(failed, style: TvText.body),
          const SizedBox(height: 12),
          TvButton(
            icon: Icons.refresh_rounded,
            label: 'Retry',
            onPressed: () => setState(_reload),
          ),
        ],
      );
    }
    final items = snap.data ?? const [];
    if (items.isEmpty) return Text(empty, style: TvText.body);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          row(items[i], i),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) return _buildTv(context);
    final compact = MediaQuery.sizeOf(context).width < 720;
    return ListView(
      padding: EdgeInsets.all(compact ? 20 : 34),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Support Orvix',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900, color: const Color(0xFFEAF0EA))),
              const SizedBox(height: 8),
              const Text(
                'Orvix is free and open source. Support development, meet the earliest supporters, and see the contributors building the project.',
                style: TextStyle(color: Color(0xFF9CA99E), height: 1.45),
              ),
              const SizedBox(height: 20),
              const Wrap(spacing: 10, runSpacing: 10, children: [
                _LinkButton('GitHub Sponsors', 'https://github.com/sponsors/ish4ra', SimpleIcons.githubsponsors, true),
                _LinkButton('Buy Me a Coffee', 'https://buymeacoffee.com/ish4ra', SimpleIcons.buymeacoffee, false),
                _LinkButton('Ko-fi', 'https://ko-fi.com/ish4ra', SimpleIcons.kofi, false),
                _LinkButton('Star on GitHub', 'https://github.com/ish4ra/Orvix', SimpleIcons.github, false),
              ]),
              const SizedBox(height: 30),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0F0C),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF263827)),
                ),
                child: Column(children: [
                  TabBar(
                    controller: _tabs,
                    isScrollable: compact,
                    dividerColor: const Color(0xFF263827),
                    indicatorColor: const Color(0xFFB9FF45),
                    labelColor: const Color(0xFFCBFF75),
                    unselectedLabelColor: const Color(0xFF9CA99E),
                    labelStyle: const TextStyle(fontWeight: FontWeight.w900),
                    tabs: const [Tab(text: 'Supporters'), Tab(text: 'Contributors')],
                  ),
                  SizedBox(
                    height: compact ? 520 : 500,
                    child: TabBarView(controller: _tabs, children: [
                      _SupportersList(future: _supporters, reload: () => setState(_reload), open: _open),
                      _ContributorsList(future: _contributors, reload: () => setState(_reload), open: _open),
                    ]),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SupportersList extends StatelessWidget {
  const _SupportersList({required this.future, required this.reload, required this.open});
  final Future<List<OrvixSupporter>> future;
  final VoidCallback reload;
  final Future<void> Function(String?) open;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<OrvixSupporter>>(
    future: future,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) return _StateMessage('Could not load supporters.', reload);
      final items = snap.data ?? const <OrvixSupporter>[];
      if (items.isEmpty) return const _EmptyMessage(icon: Icons.favorite_border_rounded, title: 'No public supporters yet', detail: 'The first public supporters will be recognized here.');
      return ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1B2A1C)),
        itemBuilder: (context, i) {
          final s = items[i];
          return ListTile(
            onTap: s.profileUrl == null ? null : () => open(s.profileUrl),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            leading: _Avatar(url: s.avatarUrl, fallback: s.name),
            title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text([s.providerLabel, s.supportType, if (s.tier?.isNotEmpty == true) s.tier!].join(' • '), style: const TextStyle(color: Color(0xFF9CA99E))),
            trailing: i < 3 ? _EarlyBadge(number: i + 1) : null,
          );
        },
      );
    },
  );
}

class _ContributorsList extends StatelessWidget {
  const _ContributorsList({required this.future, required this.reload, required this.open});
  final Future<List<OrvixContributor>> future;
  final VoidCallback reload;
  final Future<void> Function(String?) open;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<OrvixContributor>>(
    future: future,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) return _StateMessage('Could not load contributors.', reload);
      final items = snap.data ?? const <OrvixContributor>[];
      if (items.isEmpty) return const _EmptyMessage(icon: Icons.groups_outlined, title: 'No contributors found', detail: 'GitHub contributors will appear here.');
      return ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1B2A1C)),
        itemBuilder: (context, i) {
          final c = items[i];
          return ListTile(
            onTap: () => open(c.profileUrl),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            leading: _Avatar(url: c.avatarUrl, fallback: c.login),
            title: Text(c.login, style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text('${c.contributions} contribution${c.contributions == 1 ? '' : 's'}', style: const TextStyle(color: Color(0xFF9CA99E))),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18, color: Color(0xFF6E7A70)),
          );
        },
      );
    },
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.fallback});
  final String? url;
  final String fallback;
  @override
  Widget build(BuildContext context) {
    final letter = fallback.trim().isEmpty ? '?' : fallback.trim().substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: 22,
      backgroundColor: const Color(0xFF263B18),
      foregroundImage: url?.isNotEmpty == true ? NetworkImage(url!) : null,
      child: Text(letter, style: const TextStyle(color: Color(0xFFCBFF75), fontWeight: FontWeight.w900)),
    );
  }
}

class _EarlyBadge extends StatelessWidget {
  const _EarlyBadge({required this.number});
  final int number;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: const Color(0xFF263B18), borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFF426B2E))),
    child: Text('#$number', style: const TextStyle(color: Color(0xFFCBFF75), fontWeight: FontWeight.w900, fontSize: 12)),
  );
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({required this.icon, required this.title, required this.detail});
  final IconData icon; final String title; final String detail;
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(28),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 40, color: const Color(0xFF426B2E)),
      const SizedBox(height: 12),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
      const SizedBox(height: 6),
      Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9CA99E))),
    ]),
  ));
}

class _StateMessage extends StatelessWidget {
  const _StateMessage(this.message, this.reload);
  final String message; final VoidCallback reload;
  @override
  Widget build(BuildContext context) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Text(message, style: const TextStyle(color: Color(0xFF9CA99E))),
    const SizedBox(height: 12),
    OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
  ]));
}

class _LinkButton extends StatelessWidget {
  const _LinkButton(this.label, this.url, this.icon, this.primary);
  final String label; final String url; final IconData icon; final bool primary;
  Future<void> _open() => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  @override
  Widget build(BuildContext context) => primary
      ? FilledButton.icon(onPressed: _open, icon: Icon(icon, size: 18), label: Text(label))
      : OutlinedButton.icon(onPressed: _open, icon: Icon(icon, size: 18), label: Text(label));
}
