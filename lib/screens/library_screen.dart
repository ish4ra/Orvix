import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/cloud_preferences_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/platform_profile.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/torbox_service.dart';
import '../services/real_debrid_service.dart';
import '../services/premiumize_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import 'android_exo_player_screen.dart';
import 'player_screen.dart';

Future<void> _openCloudPlayer(
  BuildContext context, {
  required PlaybackService playback,
  required String url,
  required String title,
}) async {
  final preference = await PlayerEnginePreferencesService.get();
  final engine = PlayerEngineRouter.choose(
    preference: preference,
    isAndroid: Platform.isAndroid,
    url: url,
    releaseHint: title,
  );

  if (engine == PlayerEngineKind.exoPlayer && Platform.isAndroid) {
    final result = await Navigator.of(context).push<AndroidExoPlayerResult>(
      MaterialPageRoute(
        builder: (_) => AndroidExoPlayerScreen(
          url: url,
          title: title,
          autoFallbackToMpv:
              preference == PlayerEnginePreference.auto,
        ),
      ),
    );
    if (!context.mounted) return;

    final shouldFallback = result?.switchToMpv == true ||
        (preference == PlayerEnginePreference.auto &&
            result?.failed == true);
    if (!shouldFallback) return;
  }

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        playback: playback,
        url: url,
        title: title,
      ),
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.pikpak,
    required this.transfer,
    required this.torbox,
    required this.cloudPreferences,
    required this.playback,
    required this.onAuthChanged,
  });

  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final TorBoxService torbox;
  final CloudPreferencesService cloudPreferences;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  CloudProvider _provider = CloudProvider.pikpak;

  @override
  void initState() {
    super.initState();
    _restorePreferred();
  }

  Future<void> _restorePreferred() async {
    final provider = await widget.cloudPreferences.getPreferred();
    if (mounted) setState(() => _provider = provider);
  }

  Future<void> _select(CloudProvider provider) async {
    setState(() => _provider = provider);
    await widget.cloudPreferences.setPreferred(provider);
  }

  Widget _pane() {
    return _provider == CloudProvider.pikpak
        ? _PikPakPane(
            key: const ValueKey('pikpak'), pikpak: widget.pikpak, transfer: widget.transfer, playback: widget.playback, onAuthChanged: widget.onAuthChanged)
        : _provider == CloudProvider.torbox
            ? _TorBoxPane(key: const ValueKey('torbox'), torbox: widget.torbox, playback: widget.playback, onAuthChanged: widget.onAuthChanged)
            : _TokenDebridPane(
                key: ValueKey(_provider.name),
                provider: _provider,
                onAuthChanged: widget.onAuthChanged,
              );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TvMetrics.pageHorizontal,
              TvMetrics.pageTop,
              TvMetrics.pageHorizontal,
              0,
            ),
            child: TvCloudProviderTabs(
              provider: _provider,
              onSelected: _select,
            ),
          ),
          // No cross-fade on TV: two panes on screen at once would both
          // accept focus.
          Expanded(child: _pane()),
        ],
      );
    }
    final mobile = PlatformProfile.isAndroidMobile;
    return Column(
      children: [
        CloudsHeader(
          provider: _provider,
          onSelected: _select,
          mobile: mobile,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _pane(),
          ),
        ),
      ],
    );
  }
}

/// How the Clouds title and provider selector are arranged.
enum CloudsHeaderLayout {
  /// Title on the left, labelled selector on the right (wide desktop).
  inline,

  /// Labelled selector on its own line below the title.
  stacked,

  /// A dropdown below the title, for windows too narrow for the selector.
  menu,
}

/// The "Clouds" title and the provider selector.
///
/// Android Mobile keeps its fixed layout. Desktop picks a layout from the
/// width it is actually given, so a narrow Windows or macOS window never
/// squeezes the labelled segments until their labels wrap one character per
/// line. Android TV uses [TvCloudProviderTabs] instead.
class CloudsHeader extends StatelessWidget {
  const CloudsHeader({
    super.key,
    required this.provider,
    required this.onSelected,
    required this.mobile,
  });

  final CloudProvider provider;
  final ValueChanged<CloudProvider> onSelected;
  final bool mobile;

  static const _inlineGap = 24.0;

  static IconData iconFor(CloudProvider provider) {
    switch (provider) {
      case CloudProvider.pikpak:
        return Icons.cloud_outlined;
      case CloudProvider.torbox:
        return Icons.bolt_outlined;
      case CloudProvider.realDebrid:
        return Icons.cloud_done_outlined;
      case CloudProvider.premiumize:
        return Icons.cloud_queue_rounded;
    }
  }

  static TextStyle? _headingStyle(BuildContext context) =>
      Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
          );

  static double _textWidth(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Picks the desktop layout for [maxWidth], measuring the real labels with
  /// the current font and text scale instead of guessing pixel breakpoints.
  static CloudsHeaderLayout layoutFor(BuildContext context, double maxWidth) {
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    var widestLabel = 0.0;
    for (final provider in CloudProvider.values) {
      final width = _textWidth(context, provider.label, labelStyle);
      if (width > widestLabel) widestLabel = width;
    }
    // Segments share the widest segment's width: an 18px icon, an 8px gap,
    // 12px padding per side, plus slack for borders and density.
    final selectorWidth =
        CloudProvider.values.length * (widestLabel + 18 + 8 + 24 + 16);
    final headingWidth =
        _textWidth(context, 'Clouds', _headingStyle(context));
    if (headingWidth + _inlineGap + selectorWidth <= maxWidth) {
      return CloudsHeaderLayout.inline;
    }
    if (selectorWidth <= maxWidth) return CloudsHeaderLayout.stacked;
    return CloudsHeaderLayout.menu;
  }

  @override
  Widget build(BuildContext context) {
    final mobile = this.mobile;
    final providerSelector = SegmentedButton<CloudProvider>(
      segments: mobile
          ? const [
              ButtonSegment(value: CloudProvider.pikpak, label: Text('PikPak')),
              ButtonSegment(value: CloudProvider.torbox, label: Text('TorBox')),
              ButtonSegment(value: CloudProvider.realDebrid, label: Text('Real-Debrid')),
              ButtonSegment(value: CloudProvider.premiumize, label: Text('Premiumize')),
            ]
          : const [
              ButtonSegment(value: CloudProvider.pikpak, label: Text('PikPak'), icon: Icon(Icons.cloud_outlined)),
              ButtonSegment(value: CloudProvider.torbox, label: Text('TorBox'), icon: Icon(Icons.bolt_outlined)),
              ButtonSegment(value: CloudProvider.realDebrid, label: Text('Real-Debrid'), icon: Icon(Icons.cloud_done_outlined)),
              ButtonSegment(value: CloudProvider.premiumize, label: Text('Premiumize'), icon: Icon(Icons.cloud_queue_rounded)),
            ],
      selected: {provider},
      showSelectedIcon: !mobile,
      expandedInsets: mobile ? EdgeInsets.zero : null,
      style: mobile
          ? const ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              ),
              textStyle: WidgetStatePropertyAll(
                TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            )
          : null,
      onSelectionChanged: (value) => onSelected(value.first),
    );
    final heading = Text('Clouds', style: _headingStyle(context));

    return Padding(
      padding: EdgeInsets.fromLTRB(mobile ? 20 : 32, 24, mobile ? 20 : 32, 0),
      child: mobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 14),
                SizedBox(width: double.infinity, child: providerSelector),
              ],
            )
          : LayoutBuilder(
                  builder: (context, constraints) {
                    switch (layoutFor(context, constraints.maxWidth)) {
                      case CloudsHeaderLayout.inline:
                        // No Flexible here: beside a Spacer it would cap the
                        // selector at half the free width and squeeze its
                        // labels long before the window is actually narrow.
                        // Inline is only chosen when the selector fits.
                        return Row(
                          children: [
                            heading,
                            const Spacer(),
                            providerSelector,
                          ],
                        );
                      case CloudsHeaderLayout.stacked:
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: 14),
                            providerSelector,
                          ],
                        );
                      case CloudsHeaderLayout.menu:
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            heading,
                            const SizedBox(height: 14),
                            _CloudProviderMenu(
                              provider: provider,
                              onSelected: onSelected,
                            ),
                          ],
                        );
                    }
                  },
                ),
    );
  }
}

/// Compact provider picker used when the window is too narrow for the
/// labelled segments. Every provider stays listed and the selected one stays
/// visible, with its icon, in the field.
class _CloudProviderMenu extends StatelessWidget {
  const _CloudProviderMenu({required this.provider, required this.onSelected});

  final CloudProvider provider;
  final ValueChanged<CloudProvider> onSelected;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Cloud provider',
        prefixIcon: Icon(CloudsHeader.iconFor(provider)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<CloudProvider>(
          key: const ValueKey('clouds-provider-menu'),
          value: provider,
          isDense: true,
          isExpanded: true,
          items: [
            for (final option in CloudProvider.values)
              DropdownMenuItem(
                value: option,
                child: Row(
                  children: [
                    Icon(CloudsHeader.iconFor(option), size: 18),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          selectedItemBuilder: (context) => [
            for (final option in CloudProvider.values)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) onSelected(value);
          },
        ),
      ),
    );
  }
}

/// Android TV provider selector: four labelled tabs in one row, or a 2x2
/// grid when the screen is too narrow, so no label is ever squeezed.
/// Selecting a provider keeps focus on its tab.
class TvCloudProviderTabs extends StatefulWidget {
  const TvCloudProviderTabs({
    super.key,
    required this.provider,
    required this.onSelected,
  });

  final CloudProvider provider;
  final ValueChanged<CloudProvider> onSelected;

  static const tabWidth = 186.0;
  static const gap = 12.0;

  @override
  State<TvCloudProviderTabs> createState() => _TvCloudProviderTabsState();
}

class _TvCloudProviderTabsState extends State<TvCloudProviderTabs> {
  late final Map<CloudProvider, FocusNode> _nodes = {
    for (final provider in CloudProvider.values)
      provider: FocusNode(debugLabel: 'tv-cloud-${provider.name}'),
  };

  @override
  void didUpdateWidget(covariant TvCloudProviderTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The saved provider is restored after the first frame; if focus is
    // still on the tab that was selected then, follow the selection.
    if (oldWidget.provider != widget.provider &&
        _nodes[oldWidget.provider]!.hasPrimaryFocus) {
      final node = _nodes[widget.provider]!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && tvCanFocus(node)) tvRequestFocus(node);
      });
    }
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// The tab width that shows every label in full with the current font and
  /// text scale.
  double _neededTabWidth(BuildContext context) {
    var widest = 0.0;
    final style = DefaultTextStyle.of(context)
        .style
        .merge(TvText.label.copyWith(fontWeight: FontWeight.w900));
    for (final provider in CloudProvider.values) {
      final painter = TextPainter(
        text: TextSpan(text: provider.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    // Padding, icon, gap, selected dot, border, plus a little slack.
    return widest + 36 + 20 + 10 + 15 + 6 + 8;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TvPageHeader(
          title: 'Clouds',
          subtitle: 'Connect a cloud or debrid service, then play straight from it.',
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            const count = 4;
            final tab = _neededTabWidth(context)
                .clamp(TvCloudProviderTabs.tabWidth, double.infinity);
            final row = constraints.maxWidth >=
                tab * count + TvCloudProviderTabs.gap * (count - 1);
            // Too narrow for one row: a 2x2 grid, never squeezed labels.
            final width = row
                ? tab
                : (constraints.maxWidth - TvCloudProviderTabs.gap) / 2;
            return TvTabGroup(child: Wrap(
              spacing: TvCloudProviderTabs.gap,
              runSpacing: TvCloudProviderTabs.gap,
              children: [
                for (final provider in CloudProvider.values)
                  TvTab(
                    key: ValueKey('tv-cloud-tab-${provider.name}'),
                    focusNode: _nodes[provider],
                    width: width,
                    icon: CloudsHeader.iconFor(provider),
                    label: provider.label,
                    selected: provider == widget.provider,
                    preferred: provider == widget.provider,
                    onPressed: () => widget.onSelected(provider),
                  ),
              ],
            ));
          },
        ),
      ],
    );
  }
}

/// Intro block shown above a TV sign-in form.
Widget _tvCloudIntro({
  required IconData icon,
  required String title,
  required String text,
}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: TvColors.primary.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: TvColors.primary, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.section.copyWith(fontSize: 22)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(text, style: TvText.body),
      ],
    );

/// A TV sign-in form column: readable width, scrolls with focus, entered at
/// [entry] when focus comes down from the provider tabs.
Widget _tvForm(List<Widget> children, {Key? key, FocusNode? entry}) =>
    TvFocusEntry(
      entry: entry,
      child: SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.pageHorizontal,
        24,
        TvMetrics.pageHorizontal,
        TvMetrics.pageBottom,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ),
    );

Widget _tvMessage(String? message) => message == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(
          message,
          key: const ValueKey('tv-cloud-message'),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TvText.caption.copyWith(fontSize: 13.5),
        ),
      );

/// Header of a connected TV cloud library: title, then its actions.
Widget _tvLibraryHeader({
  required String title,
  required String subtitle,
  required List<Widget> actions,
}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(
          TvMetrics.pageHorizontal, 22, TvMetrics.pageHorizontal, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.section.copyWith(fontSize: 21)),
                const SizedBox(height: 4),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.caption),
              ],
            ),
          ),
          for (final action in actions) ...[
            const SizedBox(width: 12),
            action,
          ],
        ],
      ),
    );

/// On TV, moves focus to [node] once the next frame has built it (used when
/// a form is replaced by the connected view).
void _tvFocusAfterBuild(State state, FocusNode node) {
  if (!PlatformProfile.isAndroidTv) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (state.mounted && tvCanFocus(node)) tvRequestFocus(node);
  });
}

class _PikPakPane extends StatefulWidget {
  const _PikPakPane({super.key, required this.pikpak, required this.transfer, required this.playback, required this.onAuthChanged});
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;
  @override
  State<_PikPakPane> createState() => _PikPakPaneState();
}

class _PikPakPaneState extends State<_PikPakPane> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocusNode = FocusNode(debugLabel: 'pikpak-username');
  final _passwordFocusNode = FocusNode(debugLabel: 'pikpak-password');
  final _signInFocusNode = FocusNode(debugLabel: 'pikpak-sign-in');
  final _firstFileFocusNode = FocusNode(debugLabel: 'pikpak-first-file');
  final _refreshFocusNode = FocusNode(debugLabel: 'pikpak-refresh');
  final List<_FolderCrumb> _crumbs = [const _FolderCrumb('', 'My PikPak')];
  bool _checkingSession = true;
  bool _signedIn = false;
  bool _busy = false;
  String? _message;
  String? _verificationUrl;
  List<PikPakFile> _files = const [];

  String get _parentId => _crumbs.last.id;

  @override
  void initState() { super.initState(); _restore(); }
  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _signInFocusNode.dispose();
    _firstFileFocusNode.dispose();
    _refreshFocusNode.dispose();
    super.dispose();
  }

  String _formatFileSize(String? raw) {
    final bytes = int.tryParse(raw ?? '');
    if (bytes == null || bytes <= 0) return '';
    return _formatBytes(bytes);
  }

  Future<void> _restore() async {
    final signedIn = await widget.pikpak.isSignedIn;
    final username = await widget.pikpak.signedInUsername;
    if (!mounted) return;
    setState(() { _signedIn = signedIn; _checkingSession = false; if (username != null) _usernameController.text = username; });
    if (signedIn) await _refreshLibrary();
  }

  Future<void> _signIn() async {
    setState(() { _busy = true; _message = null; _verificationUrl = null; });
    try {
      final result = await widget.pikpak.login(_usernameController.text, _passwordController.text);
      if (!mounted) return;
      setState(() { _busy = false; _message = result.message; _verificationUrl = result.verificationUrl; _signedIn = result.ok; if (result.ok) _passwordController.clear(); });
      if (result.ok) { widget.onAuthChanged(); _tvFocusAfterBuild(this, _refreshFocusNode); await _refreshLibrary(); }
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Sign in failed: $e'; }); }
  }

  Future<void> _openVerification() async {
    final uri = Uri.tryParse(_verificationUrl ?? '');
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _refreshLibrary() async {
    if (!_signedIn) return;
    setState(() { _busy = true; _message = 'Loading ${_crumbs.last.name}…'; });
    try {
      final files = await widget.pikpak.listFiles(parentId: _parentId);
      if (mounted) setState(() { _files = files; _busy = false; _message = null; });
    } on PikPakVerificationRequired catch (e) {
      if (mounted) setState(() { _busy = false; _verificationUrl = e.url; _message = 'PikPak needs verification.'; });
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not load PikPak: $e'; }); }
  }

  Future<void> _playFile(PikPakFile file) async {
    setState(() { _busy = true; _message = 'Preparing ${file.name}…'; });
    try {
      final url = await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
      if (url == null || url.isEmpty) throw Exception('PikPak did not return a playable link.');
      if (!mounted) return;
      setState(() { _busy = false; _message = null; });
      await _openCloudPlayer(
        context,
        playback: widget.playback,
        url: url,
        title: file.name,
      );
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not play file: $e'; }); }
  }

  Future<void> _signOut() async {
    await widget.pikpak.logout();
    if (!mounted) return;
    setState(() { _signedIn = false; _files = const []; _crumbs..clear()..add(const _FolderCrumb('', 'My PikPak')); _message = 'Signed out.'; });
    widget.onAuthChanged();
    _tvFocusAfterBuild(this, _usernameFocusNode);
  }

  Future<void> _openFolder(_FolderCrumb crumb) async {
    _crumbs.add(crumb);
    await _refreshLibrary();
    _focusFirstFile();
  }

  Future<void> _closeFolder() async {
    _crumbs.removeLast();
    await _refreshLibrary();
    _focusFirstFile();
  }

  /// After a folder change on TV, start at the top of the new list.
  void _focusFirstFile() {
    if (!PlatformProfile.isAndroidTv || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _files.isNotEmpty ? _firstFileFocusNode : _refreshFocusNode;
      if (tvCanFocus(target)) tvRequestFocus(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) return const Center(child: CircularProgressIndicator());
    if (PlatformProfile.isAndroidTv) {
      return _signedIn ? _buildTvLibrary() : _buildTvLogin();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: _signedIn ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildTvLogin() => _tvForm(key: const PageStorageKey('pikpak-login-scroll'), entry: _usernameFocusNode, [
    _tvCloudIntro(
      icon: Icons.cloud_rounded,
      title: 'Connect PikPak',
      text: 'Browse and play your PikPak cloud library directly inside Orvix.',
    ),
    const SizedBox(height: 22),
    TvTextField(
      key: const ValueKey('tv-pikpak-username'),
      controller: _usernameController,
      focusNode: _usernameFocusNode,
      nextFocusNode: _passwordFocusNode,
      enabled: !_busy,
      label: 'Email / username',
      icon: Icons.person_outline,
      textInputAction: TextInputAction.next,
    ),
    const SizedBox(height: 14),
    TvTextField(
      key: const ValueKey('tv-pikpak-password'),
      controller: _passwordController,
      focusNode: _passwordFocusNode,
      nextFocusNode: _signInFocusNode,
      enabled: !_busy,
      obscureText: true,
      label: 'Password',
      icon: Icons.lock_outline,
    ),
    const SizedBox(height: 20),
    TvButton(
      key: const ValueKey('tv-pikpak-sign-in'),
      expanded: true,
      focusNode: _signInFocusNode,
      kind: TvButtonKind.primary,
      icon: Icons.login,
      label: 'Sign in to PikPak',
      busy: _busy,
      onPressed: _signIn,
    ),
    _tvMessage(_message),
    if (_verificationUrl != null) ...[
      const SizedBox(height: 14),
      TvButton(
        expanded: true,
        icon: Icons.verified_user_outlined,
        label: 'Open verification',
        onPressed: _openVerification,
      ),
    ],
  ]);

  Widget _buildTvLibrary() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _tvLibraryHeader(
        title: _crumbs.last.name,
        subtitle: _crumbs.map((e) => e.name).join(' / '),
        actions: [
          if (_crumbs.length > 1)
            TvButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              enabled: !_busy,
              onPressed: _closeFolder,
            ),
          TvButton(
            focusNode: _refreshFocusNode,
            icon: Icons.refresh,
            label: 'Refresh',
            busy: _busy,
            onPressed: _refreshLibrary,
          ),
          TvButton(
            icon: Icons.logout_rounded,
            label: 'Sign out',
            enabled: !_busy,
            onPressed: _signOut,
          ),
        ],
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: TvMetrics.pageHorizontal),
          child: _tvMessage(_message),
        ),
      Expanded(
        child: _files.isEmpty && !_busy
            ? const TvMessage(
                icon: Icons.folder_open_rounded,
                title: 'This folder is empty',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                    TvMetrics.pageHorizontal, 10, TvMetrics.pageHorizontal, TvMetrics.pageBottom),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final file = _files[index];
                  return TvListRow(
                    key: ValueKey('tv-pikpak-${file.id}'),
                    focusNode: index == 0 ? _firstFileFocusNode : null,
                    icon: file.isFolder ? Icons.folder_rounded : Icons.movie_rounded,
                    title: file.name,
                    subtitle: file.isFolder ? 'Folder' : [(file.mimeType ?? file.kind), _formatFileSize(file.size)].where((e) => e.trim().isNotEmpty).join(' • '),
                    trailingIcon: file.isFolder ? Icons.chevron_right_rounded : Icons.play_circle_fill_rounded,
                    enabled: !_busy,
                    onPressed: () async { if (file.isFolder) { await _openFolder(_FolderCrumb(file.id, file.name)); } else { await _playFile(file); } },
                  );
                },
              ),
      ),
    ],
  );

  Widget _buildLogin(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('pikpak-login-scroll'),
    padding: const EdgeInsets.only(bottom: 28),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: _cloudCard(
        context,
        icon: Icons.cloud_rounded,
        title: 'Connect PikPak',
        subtitle: 'Browse and play your PikPak cloud library directly inside Orvix.',
        children: [
          TextField(
            controller: _usernameController,
            focusNode: _usernameFocusNode,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Email / username',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            enabled: !_busy,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _signIn(),
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            focusNode: _signInFocusNode,
            onPressed: _busy ? null : _signIn,
            icon: const Icon(Icons.login),
            label: const Text('Sign in to PikPak'),
          ),
          if (_message != null) ...[const SizedBox(height: 12), Text(_message!, textAlign: TextAlign.center)],
          if (_verificationUrl != null) ...[const SizedBox(height: 10), OutlinedButton.icon(onPressed: _openVerification, icon: const Icon(Icons.verified_user_outlined), label: const Text('Open verification'))],
        ],
      ),
    ),
    ),
  );

  Widget _buildLibrary(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(builder: (context, constraints) => Row(children: [
        if (_crumbs.length > 1) IconButton.filledTonal(onPressed: _busy ? null : () async { _crumbs.removeLast(); await _refreshLibrary(); }, icon: const Icon(Icons.arrow_back_rounded)),
        if (_crumbs.length > 1) const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_crumbs.last.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)), Text(_crumbs.map((e) => e.name).join(' / '), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))])),
        _cloudRefreshButton(constraints, _busy ? null : _refreshLibrary),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : _signOut, child: const Text('Sign out')),
      ])),
      if (_message != null) ...[const SizedBox(height: 12), Text(_message!)],
      const SizedBox(height: 18),
      Expanded(child: ListView.separated(
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = _files[index];
          return _rowCard(
            context,
            icon: file.isFolder ? Icons.folder_rounded : Icons.movie_rounded,
            title: file.name,
            subtitle: file.isFolder ? 'Folder' : [(file.mimeType ?? file.kind), _formatFileSize(file.size)].where((e) => e.trim().isNotEmpty).join(' • '),
            trailing: file.isFolder ? Icons.chevron_right_rounded : Icons.play_circle_fill_rounded,
            onTap: _busy ? null : () async { if (file.isFolder) { _crumbs.add(_FolderCrumb(file.id, file.name)); await _refreshLibrary(); } else { await _playFile(file); } },
          );
        },
      )),
    ],
  );
}

class _TorBoxPane extends StatefulWidget {
  const _TorBoxPane({super.key, required this.torbox, required this.playback, required this.onAuthChanged});
  final TorBoxService torbox;
  final PlaybackService playback;
  final VoidCallback onAuthChanged;
  @override
  State<_TorBoxPane> createState() => _TorBoxPaneState();
}

class _TorBoxPaneState extends State<_TorBoxPane> {
  final _apiKeyController = TextEditingController();
  final _deviceLoginFocusNode = FocusNode(debugLabel: 'torbox-device');
  final _apiKeyFocusNode = FocusNode(debugLabel: 'torbox-api-key');
  final _connectFocusNode = FocusNode(debugLabel: 'torbox-connect');
  final _refreshFocusNode = FocusNode(debugLabel: 'torbox-refresh');
  bool _checking = true;
  bool _connected = false;
  bool _busy = false;
  String? _message;
  TorBoxAccount? _account;
  List<TorBoxItem> _items = const [];

  @override
  void initState() { super.initState(); _restore(); }
  @override
  void dispose() {
    _apiKeyController.dispose();
    _deviceLoginFocusNode.dispose();
    _apiKeyFocusNode.dispose();
    _connectFocusNode.dispose();
    _refreshFocusNode.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final connected = await widget.torbox.isConnected;
    if (!mounted) return;
    setState(() { _connected = connected; _checking = false; });
    if (connected) await _refresh();
  }

  Future<void> _connectApiKey() async {
    setState(() { _busy = true; _message = null; });
    try {
      await widget.torbox.connectWithApiKey(_apiKeyController.text);
      _apiKeyController.clear();
      if (!mounted) return;
      setState(() => _connected = true);
      widget.onAuthChanged();
      _tvFocusAfterBuild(this, _refreshFocusNode);
      await _refresh();
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _connectDevice() async {
    setState(() { _busy = true; _message = 'Starting TorBox device login…'; });
    try {
      final auth = await widget.torbox.startDeviceAuthorization();
      if (!mounted) return;
      setState(() => _busy = false);
      final authorized = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Connect TorBox'),
          content: SizedBox(
            width: 430,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Open TorBox, sign in, then enter/approve this device code.'),
              const SizedBox(height: 18),
              SelectableText(auth.code, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 7)),
              const SizedBox(height: 12),
              SelectableText(auth.friendlyVerificationUrl, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            OutlinedButton.icon(onPressed: () async { final uri = Uri.tryParse(auth.verificationUrl); if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication); }, icon: const Icon(Icons.open_in_new), label: const Text('Open TorBox')),
            FilledButton(autofocus: PlatformProfile.isAndroidTv, onPressed: () => Navigator.pop(dialogContext, true), child: const Text('I authorized it')),
          ],
        ),
      );
      if (authorized != true || !mounted) return;
      setState(() { _busy = true; _message = 'Checking TorBox authorization…'; });
      final attempts = ((60 / auth.intervalSeconds).ceil()).clamp(4, 24);
      var ok = false;
      for (var i = 0; i < attempts && mounted; i++) {
        try { ok = await widget.torbox.redeemDeviceAuthorization(auth.deviceCode); } catch (_) { ok = false; }
        if (ok) break;
        await Future<void>.delayed(Duration(seconds: auth.intervalSeconds));
      }
      if (!mounted) return;
      if (!ok) { setState(() { _busy = false; _message = 'TorBox authorization is still pending. Try Device Login again.'; }); return; }
      setState(() => _connected = true);
      widget.onAuthChanged();
      _tvFocusAfterBuild(this, _refreshFocusNode);
      await _refresh();
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _refresh() async {
    if (!_connected) return;
    setState(() { _busy = true; _message = 'Loading TorBox…'; });
    try {
      final account = await widget.torbox.account();
      final torrents = await widget.torbox.listTorrents(fresh: true);
      final web = await widget.torbox.listWebDownloads(fresh: true);
      if (!mounted) return;
      final items = [...torrents, ...web]..sort((a, b) => b.id.compareTo(a.id));
      setState(() { _account = account; _items = items; _busy = false; _message = null; });
    } catch (e) { if (mounted) setState(() { _busy = false; _message = 'Could not load TorBox: $e'; }); }
  }

  Future<void> _play(TorBoxItem item) async {
    if (!item.isReady) { setState(() => _message = 'This TorBox item is still preparing (${item.progress.toStringAsFixed(0)}%).'); return; }
    final file = widget.torbox.choosePlayableFile(item);
    if (file == null) { setState(() => _message = 'No playable video file found inside this TorBox item.'); return; }
    setState(() { _busy = true; _message = 'Getting TorBox stream URL…'; });
    try {
      final url = await widget.torbox.requestDownloadUrl(item, file);
      if (!mounted) return;
      setState(() { _busy = false; _message = null; });
      await _openCloudPlayer(
        context,
        playback: widget.playback,
        url: url,
        title: file.name,
      );
    } catch (e) { if (mounted) setState(() { _busy = false; _message = '$e'; }); }
  }

  Future<void> _logout() async {
    await widget.torbox.logout();
    if (!mounted) return;
    setState(() { _connected = false; _account = null; _items = const []; _message = 'Signed out.'; });
    widget.onAuthChanged();
    _tvFocusAfterBuild(this, _deviceLoginFocusNode);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    if (PlatformProfile.isAndroidTv) {
      return _connected ? _buildTvLibrary() : _buildTvLogin();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: _connected ? _buildLibrary(context) : _buildLogin(context),
    );
  }

  Widget _buildTvLogin() => _tvForm(key: const PageStorageKey('torbox-login-scroll'), entry: _deviceLoginFocusNode, [
    _tvCloudIntro(
      icon: Icons.bolt_rounded,
      title: 'Connect TorBox',
      text: 'Use TorBox device login, or enter your API key. Orvix stores the token in secure storage.',
    ),
    const SizedBox(height: 22),
    TvButton(
      key: const ValueKey('tv-torbox-device'),
      expanded: true,
      focusNode: _deviceLoginFocusNode,
      kind: TvButtonKind.primary,
      icon: Icons.devices_rounded,
      label: 'Sign in with TorBox device code',
      busy: _busy,
      onPressed: _connectDevice,
    ),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Row(children: [
        Expanded(child: Divider(color: TvColors.border)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('OR', style: TvText.caption),
        ),
        Expanded(child: Divider(color: TvColors.border)),
      ]),
    ),
    TvTextField(
      key: const ValueKey('tv-torbox-api-key'),
      controller: _apiKeyController,
      focusNode: _apiKeyFocusNode,
      nextFocusNode: _connectFocusNode,
      enabled: !_busy,
      obscureText: true,
      label: 'TorBox API key',
      icon: Icons.key_rounded,
    ),
    const SizedBox(height: 16),
    TvButton(
      key: const ValueKey('tv-torbox-connect'),
      expanded: true,
      focusNode: _connectFocusNode,
      icon: Icons.link_rounded,
      label: 'Connect with API key',
      busy: _busy,
      onPressed: _connectApiKey,
    ),
    _tvMessage(_message),
  ]);

  Widget _buildTvLibrary() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _tvLibraryHeader(
        title: _account?.email ?? 'TorBox',
        subtitle: [if ((_account?.plan ?? '').isNotEmpty) _account!.plan!, '${_items.length} cloud item${_items.length == 1 ? '' : 's'}'].join(' • '),
        actions: [
          TvButton(
            key: const ValueKey('tv-torbox-refresh'),
            focusNode: _refreshFocusNode,
            icon: Icons.refresh,
            label: 'Refresh',
            busy: _busy,
            onPressed: _refresh,
          ),
          TvButton(
            key: const ValueKey('tv-torbox-sign-out'),
            icon: Icons.logout_rounded,
            label: 'Sign out',
            enabled: !_busy,
            onPressed: _logout,
          ),
        ],
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: TvMetrics.pageHorizontal),
          child: _tvMessage(_message),
        ),
      Expanded(
        child: _items.isEmpty && !_busy
            ? const TvMessage(
                icon: Icons.inbox_rounded,
                title: 'No TorBox items yet',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                    TvMetrics.pageHorizontal, 10, TvMetrics.pageHorizontal, TvMetrics.pageBottom),
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final status = item.isReady ? 'Ready' : '${item.state.isEmpty ? 'Preparing' : item.state} • ${item.progress.toStringAsFixed(0)}%';
                  return TvListRow(
                    key: ValueKey('tv-torbox-${item.id}'),
                    icon: item.isReady ? Icons.check_circle_outline_rounded : Icons.downloading_rounded,
                    title: item.name,
                    subtitle: '$status • ${_formatBytes(item.size)} • ${item.files.length} file${item.files.length == 1 ? '' : 's'}',
                    trailingIcon: item.isReady ? Icons.play_circle_fill_rounded : Icons.chevron_right_rounded,
                    enabled: !_busy,
                    onPressed: () => _play(item),
                  );
                },
              ),
      ),
    ],
  );

  Widget _buildLogin(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey('torbox-login-scroll'),
    padding: const EdgeInsets.only(bottom: 28),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: _cloudCard(context,
        icon: Icons.bolt_rounded,
        title: 'Connect TorBox',
        subtitle: 'Use TorBox device login, or paste your API key. Orvix stores the token in secure storage.',
        children: [
          FilledButton.icon(
            focusNode: _deviceLoginFocusNode,
            onPressed: _busy ? null : _connectDevice,
            icon: const Icon(Icons.devices_rounded),
            label: const Text('Sign in with TorBox device code'),
          ),
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR')), Expanded(child: Divider())])),
          TextField(
            controller: _apiKeyController,
            focusNode: _apiKeyFocusNode,
            enabled: !_busy,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _connectApiKey(),
            decoration: const InputDecoration(
              labelText: 'TorBox API key',
              prefixIcon: Icon(Icons.key_rounded),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            focusNode: _connectFocusNode,
            onPressed: _busy ? null : _connectApiKey,
            icon: const Icon(Icons.link_rounded),
            label: const Text('Connect with API key'),
          ),
          if (_message != null) ...[const SizedBox(height: 12), Text(_message!, textAlign: TextAlign.center)],
        ],
      ),
      ),
    ),
  );

  Widget _buildLibrary(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(builder: (context, constraints) => Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_account?.email ?? 'TorBox', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          Text([if ((_account?.plan ?? '').isNotEmpty) _account!.plan!, '${_items.length} cloud item${_items.length == 1 ? '' : 's'}'].join(' • '), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        _cloudRefreshButton(constraints, _busy ? null : _refresh),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : _logout, child: const Text('Sign out')),
      ])),
      if (_message != null) ...[const SizedBox(height: 12), Text(_message!)],
      const SizedBox(height: 18),
      Expanded(child: _items.isEmpty && !_busy ? const Center(child: Text('No TorBox items yet.')) : ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = _items[index];
          final status = item.isReady ? 'Ready' : '${item.state.isEmpty ? 'Preparing' : item.state} • ${item.progress.toStringAsFixed(0)}%';
          return _rowCard(context,
            icon: item.isReady ? Icons.check_circle_outline_rounded : Icons.downloading_rounded,
            title: item.name,
            subtitle: '$status • ${_formatBytes(item.size)} • ${item.files.length} file${item.files.length == 1 ? '' : 's'}',
            trailing: item.isReady ? Icons.play_circle_fill_rounded : Icons.chevron_right_rounded,
            onTap: _busy ? null : () => _play(item),
          );
        },
      )),
    ],
  );
}

/// Below this header width a desktop window shows Refresh as an icon button,
/// leaving the library title room instead of squeezing it into a sliver.
const double _cloudHeaderCompactWidth = 520;

/// Refresh action for a PikPak / TorBox library header. Android keeps the
/// labelled button it always had; narrow desktop windows get a tooltip icon.
Widget _cloudRefreshButton(BoxConstraints constraints, VoidCallback? onPressed) {
  final compact = !Platform.isAndroid &&
      constraints.maxWidth < _cloudHeaderCompactWidth;
  if (compact) {
    return IconButton.outlined(
      tooltip: 'Refresh',
      onPressed: onPressed,
      icon: const Icon(Icons.refresh),
    );
  }
  return OutlinedButton.icon(
    onPressed: onPressed,
    icon: const Icon(Icons.refresh),
    label: const Text('Refresh'),
  );
}

Widget _cloudCard(BuildContext context, {required IconData icon, required String title, required String subtitle, required List<Widget> children}) => Container(
  padding: const EdgeInsets.all(30),
  decoration: BoxDecoration(
    color: const Color(0xFF0C110D),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: const Color(0xFF223125)),
  ),
  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    CircleAvatar(radius: 29, backgroundColor: Theme.of(context).colorScheme.primaryContainer, child: Icon(icon, size: 31)),
    const SizedBox(height: 15),
    Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
    const SizedBox(height: 7),
    Text(subtitle, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45)),
    const SizedBox(height: 24),
    ...children,
  ]),
);

Widget _rowCard(BuildContext context, {required IconData icon, required String title, required String subtitle, required IconData trailing, required VoidCallback? onTap}) => Container(
  decoration: BoxDecoration(color: const Color(0xFF0B100C), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF1D2A20))),
  child: ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    leading: CircleAvatar(backgroundColor: const Color(0xFF142017), child: Icon(icon)),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Icon(trailing),
    onTap: onTap,
  ),
);

String _formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  const kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024;
  final value = bytes.toDouble();
  if (value >= tb) return '${(value / tb).toStringAsFixed(2)} TB';
  if (value >= gb) return '${(value / gb).toStringAsFixed(2)} GB';
  if (value >= mb) return '${(value / mb).toStringAsFixed(1)} MB';
  return '${(value / kb).toStringAsFixed(1)} KB';
}

class _FolderCrumb { const _FolderCrumb(this.id, this.name); final String id; final String name; }


class _TokenDebridPane extends StatefulWidget {
  const _TokenDebridPane({super.key, required this.provider, required this.onAuthChanged});
  final CloudProvider provider;
  final VoidCallback onAuthChanged;
  @override State<_TokenDebridPane> createState()=>_TokenDebridPaneState();
}

class _TokenDebridPaneState extends State<_TokenDebridPane> {
  final _controller=TextEditingController();
  final _tokenFocusNode=FocusNode(debugLabel:'debrid-token');
  final _connectFocusNode=FocusNode(debugLabel:'debrid-connect');
  final _disconnectFocusNode=FocusNode(debugLabel:'debrid-disconnect');
  bool _connected=false, _busy=true;
  String? _message, _accountLabel;
  bool get _rd=>widget.provider==CloudProvider.realDebrid;
  @override void initState(){super.initState();_restore();}
  @override void dispose(){_controller.dispose();_tokenFocusNode.dispose();_connectFocusNode.dispose();_disconnectFocusNode.dispose();super.dispose();}
  Future<void> _restore() async {
    final connected=_rd?await RealDebridService.instance.isConnected:await PremiumizeService.instance.isConnected;
    if(!mounted)return;setState((){_connected=connected;_busy=false;});
    if(connected)await _loadAccount();
  }
  Future<void> _loadAccount() async {
    try{
      final data=_rd?await RealDebridService.instance.account():await PremiumizeService.instance.account();
      final label=_rd?(data['username']??data['email']??'Real-Debrid').toString():(data['customer_id']??data['username']??'Premiumize').toString();
      if(mounted)setState((){_accountLabel=label;_busy=false;});
    }catch(e){if(mounted)setState(()=>_message='Could not load account: $e');}
  }
  Future<void> _connect() async {
    setState((){_busy=true;_message=null;});
    try{
      if(_rd){await RealDebridService.instance.connectWithToken(_controller.text);}else{await PremiumizeService.instance.connectWithApiKey(_controller.text);}
      _controller.clear();if(!mounted)return;setState((){_connected=true;_busy=false;_message='Connected successfully.';});widget.onAuthChanged();_tvFocusAfterBuild(this,_disconnectFocusNode);await _loadAccount();
    }catch(e){if(mounted)setState((){_busy=false;_message='Connection failed: $e';});}
  }
  Future<void> _disconnect() async {
    if(_rd){await RealDebridService.instance.logout();}else{await PremiumizeService.instance.logout();}
    if(!mounted)return;setState((){_connected=false;_accountLabel=null;_message='Disconnected.';});widget.onAuthChanged();_tvFocusAfterBuild(this,_tokenFocusNode);
  }
  Widget _buildTv(String name){
    final intro=_tvCloudIntro(
      icon:_rd?Icons.cloud_done_outlined:Icons.cloud_queue_rounded,
      title:_connected?(_accountLabel??name):'Connect $name',
      text:_connected
        ? '$name is ready for torrent source playback. AI Sinhala remains disabled for debrid sources while the feature is in beta.'
        : (_rd?'Enter your Real-Debrid API token. Orvix stores it only in secure device storage.':'Enter your Premiumize API key. Orvix stores it only in secure device storage.'),
    );
    return _tvForm(key: PageStorageKey('debrid-login-${widget.provider.name}'), entry: _connected ? _disconnectFocusNode : _tokenFocusNode, _connected?[
      intro,
      const SizedBox(height: 22),
      TvButton(
        key: ValueKey('tv-${widget.provider.name}-disconnect'),
        expanded: true,
        focusNode: _disconnectFocusNode,
        icon: Icons.logout,
        label: 'Disconnect',
        busy: _busy,
        onPressed: _disconnect,
      ),
      _tvMessage(_message),
    ]:[
      intro,
      const SizedBox(height: 22),
      TvTextField(
        key: ValueKey('tv-${widget.provider.name}-token'),
        controller: _controller,
        focusNode: _tokenFocusNode,
        nextFocusNode: _connectFocusNode,
        enabled: !_busy,
        obscureText: true,
        label: _rd?'Real-Debrid API token':'Premiumize API key',
        icon: Icons.key_rounded,
      ),
      const SizedBox(height: 16),
      TvButton(
        key: ValueKey('tv-${widget.provider.name}-connect'),
        expanded: true,
        focusNode: _connectFocusNode,
        kind: TvButtonKind.primary,
        icon: Icons.link_rounded,
        label: 'Connect $name',
        busy: _busy,
        onPressed: _connect,
      ),
      _tvMessage(_message),
    ]);
  }
  @override Widget build(BuildContext context){
    final name=_rd?'Real-Debrid':'Premiumize';
    if (PlatformProfile.isAndroidTv) return _buildTv(name);
    return SingleChildScrollView(
      key: PageStorageKey('debrid-login-${widget.provider.name}'),
      padding: const EdgeInsets.all(32),
      child:_cloudCard(context,
        icon:_rd?Icons.cloud_done_outlined:Icons.cloud_queue_rounded,
        title:_connected?(_accountLabel??name):'Connect $name',
        subtitle:_connected
          ? '$name is ready for torrent source playback. AI Sinhala remains disabled for debrid sources while the feature is in beta.'
          : (_rd?'Paste your Real-Debrid API token. Orvix stores it only in secure device storage.':'Paste your Premiumize API key. Orvix stores it only in secure device storage.'),
        children:_connected?[
          OutlinedButton.icon(onPressed:_busy?null:_disconnect,icon:const Icon(Icons.logout),label:const Text('Disconnect')),
          if(_message!=null) Text(_message!),
        ]:[
          TextField(
            controller:_controller,
            focusNode:_tokenFocusNode,
            enabled:!_busy,
            obscureText:true,
            textInputAction:TextInputAction.done,
            onSubmitted:(_)=>_busy?null:_connect(),
            decoration:InputDecoration(labelText:_rd?'Real-Debrid API token':'Premiumize API key',prefixIcon:const Icon(Icons.key_rounded)),
          ),
          const SizedBox(height:12),
          FilledButton.icon(focusNode:_connectFocusNode,onPressed:_busy?null:_connect,icon:const Icon(Icons.link_rounded),label:Text('Connect $name')),
          if(_message!=null) Padding(padding:const EdgeInsets.only(top:10),child:Text(_message!)),
        ],
      ),
    );
  }
}
