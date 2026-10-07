import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_keys.dart';
import 'tv_theme.dart';

/// Scrolls every scrollable ancestor just enough to show [context] with a
/// [margin] around it, so the focused control (and a hint of its neighbours)
/// stays visible. Does nothing when it is already visible.
void tvReveal(BuildContext context, {double margin = TvMetrics.revealMargin}) {
  final object = context.findRenderObject();
  if (object is! RenderBox || !object.attached || !object.hasSize) return;
  object.showOnScreen(
    rect: (Offset.zero & object.size).inflate(margin),
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
  );
}

/// Whether [node] is attached to a mounted widget and can take focus now. A
/// node whose widget was removed keeps its old context, so checking the
/// context alone is not enough.
bool tvCanFocus(FocusNode? node) =>
    node != null &&
    node.parent != null &&
    (node.context?.mounted ?? false) &&
    node.canRequestFocus;

/// Moves focus to [node] from code (not from a DPAD move). Flutter's
/// directional traversal remembers recent moves so that pressing the opposite
/// arrow retraces them; after a jump made from code that memory is stale and
/// would skip controls, so it is cleared first.
void tvRequestFocus(FocusNode node) {
  final context = node.context;
  final scope = node.nearestScope;
  if (context != null && context.mounted && scope != null) {
    final policy = FocusTraversalGroup.maybeOf(context);
    policy?.invalidateScopeData(scope);
    final primaryScope = FocusManager.instance.primaryFocus?.nearestScope;
    if (primaryScope != null && primaryScope != scope) {
      policy?.invalidateScopeData(primaryScope);
    }
  }
  node.requestFocus();
}

/// Reading order and directional moves for TV. Left and Right only move to
/// controls on the same line; at the end of a line they stop (so the shell can
/// open the menu) instead of jumping diagonally to another row.
class TvTraversalPolicy extends ReadingOrderTraversalPolicy {
  TvTraversalPolicy({super.requestFocusCallback});

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction == TraversalDirection.left ||
        direction == TraversalDirection.right) {
      final scope = currentNode.nearestScope;
      final focused = scope?.focusedChild ?? currentNode;
      final rect = focused.rect;
      final left = direction == TraversalDirection.left;
      final sameLine = scope?.traversalDescendants.any((node) {
            if (node == focused) return false;
            final other = node.rect;
            final overlap =
                other.top < rect.bottom - 1 && other.bottom > rect.top + 1;
            if (!overlap) return false;
            return left
                ? other.center.dx < rect.center.dx &&
                    other.right <= rect.left + 1
                : other.center.dx > rect.center.dx &&
                    other.left >= rect.right - 1;
          }) ??
          false;
      if (!sameLine) return false;
    }
    return super.inDirection(currentNode, direction);
  }
}

bool _isArrow(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.arrowUp ||
    key == LogicalKeyboardKey.arrowDown ||
    key == LogicalKeyboardKey.arrowLeft ||
    key == LogicalKeyboardKey.arrowRight;

TraversalDirection? tvDirectionOf(LogicalKeyboardKey key) => switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };

typedef TvFocusWidgetBuilder = Widget Function(
    BuildContext context, bool focused);

/// A remote-focusable control: OK/Enter activates it, it scrolls itself into
/// view when focused, and [builder] draws its focused and unfocused looks.
///
/// A disabled control stays focusable, so focus never disappears when an
/// action becomes unavailable (for example while a request is running).
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.builder,
    this.onPressed,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.preferred = false,
    this.groupSelected = false,
    this.reveal = true,
    this.revealMargin = TvMetrics.revealMargin,
    this.onFocusChange,
    this.semanticLabel,
  });

  final TvFocusWidgetBuilder builder;

  /// The selected item of an enclosing [TvTabGroup]; focus entering the
  /// group lands here.
  final bool groupSelected;
  final VoidCallback? onPressed;

  /// Called when OK is held. When set, OK activates on release.
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;

  /// This control is where focus goes when its [TvFocusRegion] is entered for
  /// the first time.
  final bool preferred;
  final bool reveal;
  final double revealMargin;
  final ValueChanged<bool>? onFocusChange;
  final String? semanticLabel;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  FocusNode? _ownNode;
  bool _focused = false;
  TvHoldOk? _hold;
  TvFocusRegionState? _region;
  _TvTabGroupState? _group;

  FocusNode get _node =>
      widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'TvFocusable'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registerPreferred();
  }

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode ||
        oldWidget.preferred != widget.preferred ||
        oldWidget.groupSelected != widget.groupSelected) {
      final old = oldWidget.focusNode ?? _ownNode;
      if (oldWidget.preferred) _region?.clearPreferred(old);
      if (oldWidget.groupSelected) _group?.clearSelected(old);
      _registerPreferred();
    }
  }

  void _registerPreferred() {
    _region = TvFocusRegion.maybeOf(context);
    _group = context.findAncestorStateOfType<_TvTabGroupState>();
    if (widget.preferred) _region?.setPreferred(_node);
    if (widget.groupSelected) _group?.setSelected(_node);
  }

  @override
  void dispose() {
    _hold?.reset();
    _region?.clearPreferred(_node);
    _group?.clearSelected(_node);
    _ownNode?.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.enabled) widget.onPressed?.call();
  }

  void _longPress() {
    if (widget.enabled) widget.onLongPress?.call();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!isTvActivateKey(event.logicalKey)) return KeyEventResult.ignored;
    if (widget.onLongPress != null) {
      return (_hold ??= TvHoldOk(onTap: _activate, onHold: _longPress))
          .handle(event);
    }
    if (event is KeyDownEvent) _activate();
    // Repeats and key-ups of OK never activate anything else.
    return KeyEventResult.handled;
  }

  void _handleFocusChange(bool focused) {
    if (!focused) _hold?.reset();
    if (_focused != focused) setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    if (focused && widget.reveal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _node.hasFocus) {
          tvReveal(context, margin: widget.revealMargin);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onFocusChange: _handleFocusChange,
      onKeyEvent: _handleKey,
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        focused: _focused,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _node.requestFocus();
            _activate();
          },
          onLongPress: widget.onLongPress == null ? null : _longPress,
          child: widget.builder(context, _focused),
        ),
      ),
    );
  }
}

/// One focus area of the TV interface (a screen, the navigation).
///
/// It remembers its last focused control, so leaving and coming back lands on
/// the same item. The first time it is entered, focus goes to the control
/// marked [TvFocusable.preferred], or else to its first control. Directional
/// moves stop at its edges instead of wrapping around.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child, this.debugLabel});

  final Widget child;
  final String? debugLabel;

  static TvFocusRegionState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<TvFocusRegionState>();

  @override
  State<TvFocusRegion> createState() => TvFocusRegionState();
}

class TvFocusRegionState extends State<TvFocusRegion> {
  late final FocusScopeNode scope = FocusScopeNode(
    debugLabel: widget.debugLabel ?? 'TvFocusRegion',
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  FocusNode? _preferred;
  FocusNode? _lastFocused;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_trackFocus);
  }

  /// Remembers the last control focused in this region. Switching to another
  /// destination hides the region, which drops its focus; this memory is what
  /// brings the user back to the same control.
  void _trackFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == scope) return;
    if (primary.ancestors.contains(scope)) _lastFocused = primary;
  }

  void setPreferred(FocusNode node) => _preferred = node;

  void clearPreferred(FocusNode? node) {
    if (node != null && _preferred == node) _preferred = null;
  }

  static bool _usable(FocusNode? node) => tvCanFocus(node);

  /// Whether a control in this region can take focus right now.
  bool get hasFocusableControl => _firstControl() != null;

  FocusNode? _firstControl() {
    final policy = FocusTraversalGroup.maybeOf(context) ?? TvTraversalPolicy();
    try {
      final first = policy.findFirstFocus(scope, ignoreCurrentFocus: true);
      return first == null || first == scope || !_usable(first) ? null : first;
    } catch (_) {
      return null;
    }
  }

  /// Focuses the remembered control, else the preferred one, else the first.
  /// Returns false when the region has nothing focusable.
  bool focusInitial() {
    if (_usable(_lastFocused)) {
      tvRequestFocus(_lastFocused!);
      return true;
    }
    final remembered = scope.focusedChild;
    if (remembered != scope && _usable(remembered)) {
      tvRequestFocus(remembered!);
      return true;
    }
    if (_usable(_preferred)) {
      tvRequestFocus(_preferred!);
      return true;
    }
    final first = _firstControl();
    if (first == null) return false;
    tvRequestFocus(first);
    return true;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_trackFocus);
    scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: scope,
      child: FocusTraversalGroup(
        policy: TvTraversalPolicy(),
        child: widget.child,
      ),
    );
  }
}

/// A text field for the remote.
///
/// Moving focus onto it never opens the on-screen keyboard (which would take
/// over the DPAD). OK starts typing; the keyboard's Done/Next key, or DPAD
/// up/down, ends typing and moves on. Down goes to [nextFocusNode] when set.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.nextFocusNode,
    this.label,
    this.hint,
    this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.autofocus = false,
    this.preferred = false,
    this.width,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final FocusNode? nextFocusNode;
  final String? label;
  final String? hint;
  final IconData? icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool autofocus;
  final bool preferred;
  final double? width;

  @override
  State<TvTextField> createState() => TvTextFieldState();
}

class TvTextFieldState extends State<TvTextField> {
  FocusNode? _ownNode;
  bool _editing = false;
  bool _focused = false;
  TvFocusRegionState? _region;

  FocusNode get _node =>
      widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'TvTextField'));

  /// Whether the field is accepting text (the keyboard is attached).
  bool get editing => _editing;

  @override
  void initState() {
    super.initState();
    _node.onKeyEvent = _handleKey;
    _node.addListener(_handleFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _region = TvFocusRegion.maybeOf(context);
    if (widget.preferred) _region?.setPreferred(_node);
  }

  @override
  void didUpdateWidget(covariant TvTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      final old = oldWidget.focusNode ?? _ownNode;
      old?.removeListener(_handleFocus);
      if (old?.onKeyEvent == _handleKey) old?.onKeyEvent = null;
      _node.onKeyEvent = _handleKey;
      _node.addListener(_handleFocus);
    }
    if (!widget.enabled && _editing) _editing = false;
  }

  @override
  void dispose() {
    _node.removeListener(_handleFocus);
    if (_node.onKeyEvent == _handleKey) _node.onKeyEvent = null;
    _region?.clearPreferred(_node);
    _ownNode?.dispose();
    super.dispose();
  }

  void _handleFocus() {
    final focused = _node.hasFocus;
    if (focused == _focused) return;
    setState(() {
      _focused = focused;
      if (!focused) _editing = false;
    });
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _node.hasFocus) tvReveal(context);
      });
    }
  }

  void startEditing() {
    if (!widget.enabled) return;
    if (!_node.hasFocus) _node.requestFocus();
    setState(() => _editing = true);
  }

  void _stopEditing() {
    if (_editing) setState(() => _editing = false);
  }

  bool _move(TraversalDirection direction) {
    if (direction == TraversalDirection.down) {
      final next = widget.nextFocusNode;
      if (tvCanFocus(next)) {
        tvRequestFocus(next!);
        return true;
      }
    }
    return _node.focusInDirection(direction);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      return !_editing && (isTvActivateKey(key) || _isArrow(key))
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final direction = tvDirectionOf(key);
    if (_editing) {
      if (direction == TraversalDirection.up ||
          direction == TraversalDirection.down) {
        _stopEditing();
        _move(direction!);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select && event is KeyDownEvent) {
        // DPAD OK while typing: bring the keyboard back if it was dismissed.
        _stopEditing();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _node.hasFocus) startEditing();
        });
        return KeyEventResult.handled;
      }
      // Everything else (caret movement, characters) belongs to the text.
      return KeyEventResult.ignored;
    }
    if (isTvActivateKey(key)) {
      if (event is KeyDownEvent) startEditing();
      return KeyEventResult.handled;
    }
    if (direction != null) {
      // Not moving lets an enclosing area react, e.g. Left opens the menu.
      return _move(direction) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  void _submitted(String value) {
    _stopEditing();
    widget.onSubmitted?.call(value);
    final next = widget.nextFocusNode;
    if (mounted && tvCanFocus(next)) tvRequestFocus(next!);
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _editing;
    final borderColor = _editing
        ? TvColors.lime
        : _focused
            ? TvColors.primary
            : TvColors.border;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );
    final field = TextField(
      controller: widget.controller,
      focusNode: _node,
      autofocus: widget.autofocus,
      // Stays enabled so it keeps focus while its form is busy; editing is
      // what is switched off instead.
      readOnly: !_editing || !widget.enabled,
      showCursor: _editing,
      enableInteractiveSelection: _editing,
      obscureText: widget.obscureText,
      autocorrect: false,
      enableSuggestions: !widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onTap: startEditing,
      onChanged: widget.onChanged,
      onSubmitted: _submitted,
      // Keeps focus on the field; _submitted decides where it goes.
      onEditingComplete: () {},
      style: TextStyle(
        fontSize: 16,
        color: widget.enabled ? TvColors.text : TvColors.textDim,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: _focused && !_editing && widget.controller.text.isEmpty
            ? 'Press OK to type'
            : widget.hint,
        prefixIcon: widget.icon == null
            ? null
            : Icon(widget.icon,
                color: active ? TvColors.primary : TvColors.textMuted),
        suffixIcon: _focused && !_editing
            ? const Icon(Icons.keyboard_rounded, color: TvColors.textMuted)
            : null,
        filled: true,
        fillColor: active ? TvColors.cardFocused : TvColors.card,
        enabledBorder:
            border(borderColor, _focused ? TvMetrics.focusBorder : 1),
        focusedBorder: border(borderColor, TvMetrics.focusBorder),
      ),
    );
    return SizedBox(width: widget.width, child: field);
  }
}

/// A row of tabs (providers, filters, seasons). Moving into the row from
/// outside lands on the selected tab, not on whichever tab happens to be
/// geometrically closest; moving within the row is unchanged.
class TvTabGroup extends StatefulWidget {
  const TvTabGroup({super.key, required this.child});

  final Widget child;

  @override
  State<TvTabGroup> createState() => _TvTabGroupState();
}

class _TvTabGroupState extends State<TvTabGroup> {
  FocusNode? _selected;

  void setSelected(FocusNode node) => _selected = node;

  void clearSelected(FocusNode? node) {
    if (node != null && _selected == node) _selected = null;
  }

  void _handleFocus(bool hasFocus) {
    final selected = _selected;
    if (!hasFocus || !tvCanFocus(selected) || selected!.hasPrimaryFocus) {
      return;
    }
    tvRequestFocus(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _handleFocus,
      child: widget.child,
    );
  }
}

/// A block (such as a sign-in form) that is entered at [entry]: focus moving
/// into it from outside lands there instead of on the geometrically nearest
/// control.
class TvFocusEntry extends StatelessWidget {
  const TvFocusEntry({super.key, required this.entry, required this.child});

  final FocusNode? entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (hasFocus) {
        final node = entry;
        if (hasFocus && tvCanFocus(node) && !node!.hasPrimaryFocus) {
          tvRequestFocus(node);
        }
      },
      child: child,
    );
  }
}
