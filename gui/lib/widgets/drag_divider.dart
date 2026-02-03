import 'package:flutter/material.dart';

/// A draggable vertical divider that reports a 1D "position" based on pointer movement.
///
/// This uses the "drag start global position + initial position" model (instead of
/// incremental deltas) so clamping in the consumer feels natural.
///
/// Ported from /Users/nhj/Codes/dev-sync/dcf-cleaner.
class DragDivider extends StatefulWidget {
  const DragDivider({
    super.key,
    required this.getInitialPosition,
    required this.onPositionChanged,
    this.cursor = SystemMouseCursors.resizeLeftRight,
    this.hitWidth = 10,
    this.lineWidth = 1,
    this.lineColor,
    this.padding = EdgeInsets.zero,
  });

  final double Function() getInitialPosition;
  final ValueChanged<double> onPositionChanged;

  final MouseCursor cursor;

  /// The width of the draggable hit area.
  final double hitWidth;

  /// The thickness of the visible divider line.
  final double lineWidth;

  final Color? lineColor;
  final EdgeInsets padding;

  @override
  State<DragDivider> createState() => _DragDividerState();
}

class _DragDividerState extends State<DragDivider> {
  double? _dragStartGlobalX;
  double? _initialPosition;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _dragStartGlobalX = details.globalPosition.dx;
        _initialPosition = widget.getInitialPosition();
      },
      onHorizontalDragUpdate: (details) {
        final startX = _dragStartGlobalX;
        final initial = _initialPosition;
        if (startX == null || initial == null) return;
        final dragDelta = details.globalPosition.dx - startX;
        widget.onPositionChanged(initial + dragDelta);
      },
      onHorizontalDragEnd: (_) {
        _dragStartGlobalX = null;
        _initialPosition = null;
      },
      onHorizontalDragCancel: () {
        _dragStartGlobalX = null;
        _initialPosition = null;
      },
      child: MouseRegion(
        cursor: widget.cursor,
        child: Padding(
          padding: widget.padding,
          child: SizedBox(
            width: widget.hitWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: widget.lineWidth,
                color: widget.lineColor ?? Theme.of(context).dividerColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

