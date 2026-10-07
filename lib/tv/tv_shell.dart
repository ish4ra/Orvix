import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_focus.dart';
import 'tv_theme.dart';

class TvDestination {
  const TvDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// The Android TV app frame: a side navigation that shows icons while the
/// content has focus and expands with labels when it is focused itself.
///
/// Remote model:
/// * In the navigation, Up/Down move between destinations, OK opens one and
///   moves into it, Right moves into the current destination.
/// * In a destination, the arrows move inside it. Left at its left edge opens
///   the navigation. Moves stop at the other edges.
/// * Back on a destination other than Home returns to Home; on Home it leaves
///   Orvix as usual. Pushed routes and dialogs handle Back themselves first.
///
/// Each destination is a [TvFocusRegion]: it remembers its last focused
/// control. If focus is ever lost (a control disappears or is disabled), the
/// shell puts it back on the current destination.
class TvShell extends StatefulWidget {
  const TvShell({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.screenBuilder,
    this.brand,
  });

  final List<TvDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget Function(BuildContext context, int index) screenBuilder;
  final Widget Function(bool expanded)? brand;

  static const homeIndex = 0;

  @override
  State<TvShell> createState() => TvShellState();
}

class TvShellState extends State<TvShell> {
  late final List<GlobalKey<TvFocusRegionState>> _regions = List.generate(
    widget.destinations.length,
    (i) => GlobalKey<TvFocusRegionState>(debugLabel: 'tv-region-$i'),
  );
  late final List<FocusNode> _navNodes = List.generate(
    widget.destinations.length,
    (i) => FocusNode(debugLabel: 'tv-nav-${widget.destinations[i].label}'),
  );
  final FocusScopeNode _navScope = FocusScopeNode(
    debugLabel: 'tv-navigation',
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  final Set<int> _visited = <int>{};
  bool _navExpanded = false;
  bool _guardScheduled = false;

  bool get navigationHasFocus => _navScope.hasFocus;

  @override
  void initState() {
    super.initState();
    _visited.add(widget.selectedIndex);
    _navScope.addListener(_handleNavFocus);
    FocusManager.instance.addListener(_scheduleGuard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!focusContent()) focusNavigation();
    });
  }

  @override
  void didUpdateWidget(covariant TvShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.selectedIndex);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_scheduleGuard);
    _navScope.removeListener(_handleNavFocus);
    _navScope.dispose();
    for (final node in _navNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _handleNavFocus() {
    final expanded = _navScope.hasFocus;
    if (expanded != _navExpanded && mounted) {
      setState(() => _navExpanded = expanded);
    }
  }

  /// Moves focus into the current destination. False when it has nothing
  /// focusable yet (for example while it is loading).
  bool focusContent() {
    final region = _regions[widget.selectedIndex].currentState;
    return region != null && region.focusInitial();
  }

  void focusNavigation() {
    final node = _navNodes[widget.selectedIndex];
    if (tvCanFocus(node)) tvRequestFocus(node);
  }

  void _select(int index, {required bool enterContent}) {
    if (index != widget.selectedIndex) {
      setState(() => _visited.add(index));
      widget.onSelected(index);
    }
    // The destination becomes focusable after the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!enterContent || !focusContent()) focusNavigation();
    });
  }

  KeyEventResult _handleNavigationKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      focusContent();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleContentKey(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return KeyEventResult.ignored;
    // Left inside a field being typed in moves the caret.
    final field = primary.context?.findAncestorStateOfType<TvTextFieldState>();
    if (field != null && field.editing) return KeyEventResult.ignored;
    if (!primary.focusInDirection(TraversalDirection.left)) focusNavigation();
    return KeyEventResult.handled;
  }

  void _scheduleGuard() {
    if (_guardScheduled) return;
    _guardScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guardScheduled = false;
      _restoreLostFocus();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Puts focus back when nothing visible holds it, e.g. after the focused
  /// control was removed, so the remote never ends up controlling nothing.
  void _restoreLostFocus() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) return;
    if (primary == _navScope || !focusContent()) focusNavigation();
  }

  void _handleBack(bool didPop, Object? result) {
    if (didPop) return;
    _select(TvShell.homeIndex, enterContent: !_navScope.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final destinations = widget.destinations;
    return PopScope(
      // Home with nothing pushed: Back leaves Orvix normally.
      canPop: widget.selectedIndex == TvShell.homeIndex,
      onPopInvokedWithResult: _handleBack,
      child: Scaffold(
        backgroundColor: TvColors.background,
        body: Stack(
          children: [
            Positioned.fill(
              left: TvMetrics.navCollapsedWidth,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _handleContentKey,
                child: ClipRect(
                  child: IndexedStack(
                    index: widget.selectedIndex,
                    sizing: StackFit.expand,
                    children: [
                      for (var i = 0; i < destinations.length; i++)
                        _visited.contains(i)
                            ? TvFocusRegion(
                                key: _regions[i],
                                debugLabel: 'tv-${destinations[i].label}',
                                child: widget.screenBuilder(context, i),
                              )
                            : const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ),
            // Dims the content while the expanded navigation covers it.
            Positioned.fill(
              left: TvMetrics.navCollapsedWidth,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _navExpanded ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xE6050806), Color(0x66050806)],
                        stops: [.12, .7],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _TvNavigation(
                scope: _navScope,
                nodes: _navNodes,
                destinations: destinations,
                selectedIndex: widget.selectedIndex,
                expanded: _navExpanded,
                brand: widget.brand,
                onKeyEvent: _handleNavigationKey,
                onSelected: (index) => _select(index, enterContent: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvNavigation extends StatelessWidget {
  const _TvNavigation({
    required this.scope,
    required this.nodes,
    required this.destinations,
    required this.selectedIndex,
    required this.expanded,
    required this.brand,
    required this.onKeyEvent,
    required this.onSelected,
  });

  final FocusScopeNode scope;
  final List<FocusNode> nodes;
  final List<TvDestination> destinations;
  final int selectedIndex;
  final bool expanded;
  final Widget Function(bool expanded)? brand;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      width:
          expanded ? TvMetrics.navExpandedWidth : TvMetrics.navCollapsedWidth,
      decoration: BoxDecoration(
        color: TvColors.canvas,
        border: const Border(right: BorderSide(color: Color(0xFF141C15))),
        boxShadow: expanded
            ? const [
                BoxShadow(
                  color: Color(0xAA000000),
                  blurRadius: 28,
                  offset: Offset(6, 0),
                ),
              ]
            : const [],
      ),
      child: ClipRect(
        // Laid out at full width and clipped while collapsed, so labels never
        // wrap or overflow during the animation.
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: TvMetrics.navExpandedWidth,
          maxWidth: TvMetrics.navExpandedWidth,
          child: FocusScope(
            node: scope,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: onKeyEvent,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 560;
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: compact ? 18 : 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 44,
                          child: brand?.call(expanded) ?? const SizedBox(),
                        ),
                        SizedBox(height: compact ? 10 : 22),
                        Expanded(
                          child: SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            child: Column(
                              children: [
                                for (var i = 0; i < destinations.length; i++)
                                  _TvNavItem(
                                    key: ValueKey(
                                        'tv-nav-${destinations[i].label}'),
                                    node: nodes[i],
                                    destination: destinations[i],
                                    selected: i == selectedIndex,
                                    expanded: expanded,
                                    height: compact ? 46 : 52,
                                    onPressed: () => onSelected(i),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvNavItem extends StatelessWidget {
  const _TvNavItem({
    super.key,
    required this.node,
    required this.destination,
    required this.selected,
    required this.expanded,
    required this.height,
    required this.onPressed,
  });

  final FocusNode node;
  final TvDestination destination;
  final bool selected;
  final bool expanded;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: node,
      onPressed: onPressed,
      revealMargin: 8,
      semanticLabel: destination.label,
      builder: (context, focused) {
        final iconColor = focused
            ? TvColors.text
            : selected
                ? TvColors.primary
                : TvColors.textDim;
        return SizedBox(
          height: height,
          child: Stack(
            children: [
              // The focus pill spans the expanded width.
              Positioned(
                left: 12,
                right: 14,
                top: 3,
                bottom: 3,
                child: AnimatedContainer(
                  duration: TvMetrics.focusDuration,
                  decoration: BoxDecoration(
                    color: focused
                        ? TvColors.cardFocused
                        : selected && expanded
                            ? const Color(0xFF111A11)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: focused ? TvColors.primary : Colors.transparent,
                      width: TvMetrics.focusBorder,
                    ),
                  ),
                ),
              ),
              // Selected marker, visible in both widths.
              Positioned(
                left: 4,
                top: height / 2 - 11,
                child: AnimatedContainer(
                  duration: TvMetrics.focusDuration,
                  width: 4,
                  height: 22,
                  decoration: BoxDecoration(
                    color: selected ? TvColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Row(
                children: [
                  SizedBox(
                    width: TvMetrics.navCollapsedWidth,
                    child: Icon(
                      selected ? destination.selectedIcon : destination.icon,
                      size: 25,
                      color: iconColor,
                    ),
                  ),
                  Expanded(
                    child: AnimatedOpacity(
                      opacity: expanded ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: Text(
                        destination.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused
                              ? TvColors.text
                              : selected
                                  ? TvColors.lime
                                  : TvColors.textMuted,
                          fontSize: 16,
                          fontWeight: focused || selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
