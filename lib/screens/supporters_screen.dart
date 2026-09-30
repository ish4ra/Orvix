import 'package:flutter/material.dart';
import '../services/supporters_service.dart';

class SupportersScreen extends StatefulWidget {
  const SupportersScreen({super.key});
  @override State<SupportersScreen> createState() => _SupportersScreenState();
}
class _SupportersScreenState extends State<SupportersScreen> with SingleTickerProviderStateMixin {
  late Future<List<OrvixSupporter>> _supporters;
  late Future<List<OrvixContributor>> _contributors;
  late final TabController _tabs;
  @override void initState() { super.initState(); _tabs = TabController(length: 2, vsync: this); _supporters = SupportersService.fetchPublicSupporters(); _contributors = SupportersService.fetchContributors(); }
  @override void dispose() { _tabs.dispose(); super.dispose(); }
  void _reload() => setState(() { _supporters = SupportersService.fetchPublicSupporters(); _contributors = SupportersService.fetchContributors(); });
  @override Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(34),
    children: [ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 920),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Supporters & Contributors', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text('Thank you to everyone helping Orvix stay independent and open source.', style: TextStyle(color: Color(0xFF9CA99E), height: 1.45)),
        const SizedBox(height: 20),
        TabBar(controller: _tabs, isScrollable: true, tabs: const [Tab(text: 'Supporters'), Tab(text: 'Contributors')]),
        const SizedBox(height: 18),
        SizedBox(height: 560, child: TabBarView(controller: _tabs, children: [
        SingleChildScrollView(child: FutureBuilder<List<OrvixSupporter>>(future: _supporters, builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()));
          if (snapshot.hasError) return _MessageCard(icon: Icons.cloud_off_rounded, title: 'Could not load supporters', subtitle: 'Check your connection and try again.', action: TextButton(onPressed: _reload, child: const Text('Retry')));
          final supporters = snapshot.data ?? const <OrvixSupporter>[];
          if (supporters.isEmpty) return const _MessageCard(icon: Icons.favorite_border_rounded, title: 'Supporters wall', subtitle: 'Public supporters will appear here automatically.');
          return Container(
            decoration: BoxDecoration(color: const Color(0xFF0D120E), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF263827))),
            child: ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: supporters.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
              itemBuilder: (context, index) => _SupporterTile(supporter: supporters[index])),
          );
        })),
        SingleChildScrollView(child: FutureBuilder<List<OrvixContributor>>(future: _contributors, builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()));
          if (snapshot.hasError) return _MessageCard(icon: Icons.cloud_off_rounded, title: 'Could not load contributors', subtitle: 'GitHub contributors are temporarily unavailable.', action: TextButton(onPressed: _reload, child: const Text('Retry')));
          final contributors = snapshot.data ?? const <OrvixContributor>[];
          if (contributors.isEmpty) return const _MessageCard(icon: Icons.code_rounded, title: 'Contributors', subtitle: 'GitHub contributors will appear here.');
          return Container(decoration: BoxDecoration(color: const Color(0xFF0D120E), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF263827))), child: ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: contributors.length, separatorBuilder: (_, __) => const Divider(height: 1, indent: 76), itemBuilder: (context, index) { final item = contributors[index]; return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), leading: CircleAvatar(radius: 24, backgroundColor: const Color(0xFF172416), backgroundImage: item.avatarUrl != null ? NetworkImage(item.avatarUrl!) : null, child: item.avatarUrl == null ? const Icon(Icons.code_rounded, color: Color(0xFFCBFF75)) : null), title: Text(item.login, style: const TextStyle(fontWeight: FontWeight.w900)), subtitle: Text('${item.contributions} contribution${item.contributions == 1 ? '' : 's'}')); }));
        })),
        ])),
      ]),
    )],
  );
}
class _SupporterTile extends StatelessWidget {
  const _SupporterTile({required this.supporter});
  final OrvixSupporter supporter;
  @override Widget build(BuildContext context) {
    final avatar = supporter.avatarUrl;
    final month = const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][supporter.since.month - 1];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      leading: CircleAvatar(radius: 24, backgroundColor: const Color(0xFF172416),
        backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
        child: avatar == null || avatar.isEmpty ? Text(supporter.name.characters.first.toUpperCase(), style: const TextStyle(color: Color(0xFFCBFF75), fontWeight: FontWeight.w900)) : null),
      title: Text(supporter.name, style: const TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Wrap(spacing: 8, runSpacing: 4, children: [
        Text(supporter.tier ?? supporter.supportType),
        Text('• ${supporter.providerLabel}', style: const TextStyle(color: Color(0xFFCBFF75))),
        Text('• $month ${supporter.since.year}'),
      ])),
    );
  }
}
class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.icon, required this.title, required this.subtitle, this.action});
  final IconData icon; final String title, subtitle; final Widget? action;
  @override Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(color: const Color(0xFF0D120E), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF263827))),
    child: Row(children: [Icon(icon, color: const Color(0xFFB9FF45)), const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w900)), const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: Color(0xFF9CA99E)))])),
      if (action != null) action!]),
  );
}
