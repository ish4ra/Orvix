import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class HorizontalScrollRail extends StatefulWidget {
  const HorizontalScrollRail({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.separatorWidth = 14,
    this.scrollStep = 620,
    this.showArrows = true,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;
  final double separatorWidth;
  final double scrollStep;
  final bool showArrows;

  @override
  State<HorizontalScrollRail> createState() => _HorizontalScrollRailState();
}

class _HorizontalScrollRailState extends State<HorizontalScrollRail> {
  final ScrollController _controller = ScrollController();
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncButtons());
  }

  @override
  void didUpdateWidget(covariant HorizontalScrollRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncButtons());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_syncButtons)
      ..dispose();
    super.dispose();
  }

  void _syncButtons() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final back = position.pixels > position.minScrollExtent + 2;
    final forward = position.pixels < position.maxScrollExtent - 2;
    if (back == _canGoBack && forward == _canGoForward) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  Future<void> _move(double delta) async {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (_controller.offset + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    await _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final delta = dx.abs() > dy.abs() ? dx : dy;
    if (delta.abs() < .5) return;

    // Claim desktop wheel/trackpad signals for this rail before the outer
    // vertical CustomScrollView can consume them. Without the resolver the
    // details page can scroll vertically while the episode row appears stuck.
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (resolvedEvent) {
        if (resolvedEvent is! PointerScrollEvent ||
            !_controller.hasClients) {
          return;
        }
        final resolvedDx = resolvedEvent.scrollDelta.dx;
        final resolvedDy = resolvedEvent.scrollDelta.dy;
        final resolvedDelta = resolvedDx.abs() > resolvedDy.abs()
            ? resolvedDx
            : resolvedDy;
        _controller.jumpTo(
          (_controller.offset + resolvedDelta)
              .clamp(
                _controller.position.minScrollExtent,
                _controller.position.maxScrollExtent,
              )
              .toDouble(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 0) return const SizedBox.shrink();

    final rail = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        dragDevices: const <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      ),
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: ListView.separated(
          controller: _controller,
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          padding: widget.padding,
          itemCount: widget.itemCount,
          separatorBuilder: (_, __) => SizedBox(width: widget.separatorWidth),
          itemBuilder: widget.itemBuilder,
        ),
      ),
    );

    if (!widget.showArrows) {
      return SizedBox(height: widget.height, child: rail);
    }

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(child: rail),
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: _RailArrow(
                icon: Icons.chevron_left_rounded,
                enabled: _canGoBack,
                onPressed: () => _move(-widget.scrollStep),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: _RailArrow(
                icon: Icons.chevron_right_rounded,
                enabled: _canGoForward,
                onPressed: () => _move(widget.scrollStep),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailArrow extends StatelessWidget {
  const _RailArrow({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0,
        duration: const Duration(milliseconds: 130),
        child: Material(
          color: const Color(0xE6171C18),
          elevation: 7,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Icon(
                icon,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
