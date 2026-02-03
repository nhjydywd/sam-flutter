import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

@immutable
class PromptPoint {
  const PromptPoint({
    required this.x,
    required this.y,
    required this.label,
  });

  final double x; // image pixel X
  final double y; // image pixel Y
  final int label; // 1=positive, 0=negative
}

@immutable
class _ContainLayout {
  const _ContainLayout({
    required this.destRect,
    required this.scale,
  });

  final Rect destRect;
  final double scale;
}

_ContainLayout _computeContainLayout({
  required Size canvasSize,
  required int imageWidth,
  required int imageHeight,
}) {
  final iw = imageWidth.toDouble();
  final ih = imageHeight.toDouble();
  final cw = canvasSize.width;
  final ch = canvasSize.height;

  if (iw <= 0 || ih <= 0 || cw <= 0 || ch <= 0) {
    return const _ContainLayout(destRect: Rect.zero, scale: 1.0);
  }

  final scale = math.min(cw / iw, ch / ih);
  final dw = iw * scale;
  final dh = ih * scale;
  final dx = (cw - dw) / 2.0;
  final dy = (ch - dh) / 2.0;
  return _ContainLayout(destRect: Rect.fromLTWH(dx, dy, dw, dh), scale: scale);
}

Offset? mapLocalToImagePx({
  required Offset localPosition,
  required Size canvasSize,
  required int imageWidth,
  required int imageHeight,
}) {
  final layout = _computeContainLayout(
    canvasSize: canvasSize,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  final r = layout.destRect;
  if (r.isEmpty) return null;
  // Be forgiving: clamp clicks to the displayed image rect.
  final clampedX = localPosition.dx.clamp(r.left, r.right);
  final clampedY = localPosition.dy.clamp(r.top, r.bottom);
  final x = (clampedX - r.left) / layout.scale;
  final y = (clampedY - r.top) / layout.scale;
  final maxX = math.max(0.0, imageWidth.toDouble() - 1.0);
  final maxY = math.max(0.0, imageHeight.toDouble() - 1.0);
  return Offset(x.clamp(0.0, maxX), y.clamp(0.0, maxY));
}

class SegmentationPreview extends StatelessWidget {
  const SegmentationPreview({
    super.key,
    required this.image,
    this.maskAlpha,
    this.points = const <PromptPoint>[],
    this.onAddPoint,
    // Outside-mask brightness multiplier. 0=black, 1=no dim.
    this.dimFactor = 0.35,
  });

  final ui.Image image;
  // Expected to be an RGBA image with alpha=mask (0..255).
  final ui.Image? maskAlpha;
  final List<PromptPoint> points;
  final void Function(PromptPoint point)? onAddPoint;
  final double dimFactor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: onAddPoint == null
              ? null
              : (event) {
                  final isPrimary = event.buttons == kPrimaryMouseButton ||
                      (event.kind == ui.PointerDeviceKind.touch &&
                          event.buttons == 0);
                  final isSecondary = event.buttons == kSecondaryMouseButton;
                  if (!isPrimary && !isSecondary) return;
                  final mapped = mapLocalToImagePx(
                    localPosition: event.localPosition,
                    canvasSize: size,
                    imageWidth: image.width,
                    imageHeight: image.height,
                  );
                  if (mapped == null) return;
                  onAddPoint!(
                    PromptPoint(
                      x: mapped.dx,
                      y: mapped.dy,
                      label: isSecondary ? 0 : 1,
                    ),
                  );
                },
          child: CustomPaint(
            painter: _SegmentationPainter(
              image: image,
              maskAlpha: maskAlpha,
              points: points,
              dimFactor: dimFactor,
              theme: Theme.of(context),
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _SegmentationPainter extends CustomPainter {
  _SegmentationPainter({
    required this.image,
    required this.maskAlpha,
    required this.points,
    required this.dimFactor,
    required this.theme,
  });

  final ui.Image image;
  final ui.Image? maskAlpha;
  final List<PromptPoint> points;
  final double dimFactor;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = _computeContainLayout(
      canvasSize: size,
      imageWidth: image.width,
      imageHeight: image.height,
    );
    final dest = layout.destRect;
    if (dest.isEmpty) return;

    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    // 1) Base image.
    canvas.drawImageRect(image, src, dest, Paint());

    // 2) Dim the whole image, and if a mask exists, "punch out" the masked
    // region so it stays at original brightness.
    final layerRect = dest.inflate(1);
    canvas.saveLayer(layerRect, Paint());

    final overlayAlpha = (1.0 - dimFactor).clamp(0.0, 1.0);
    canvas.drawRect(
      dest,
      Paint()..color = Colors.black.withValues(alpha: overlayAlpha),
    );

    final mask = maskAlpha;
    if (mask != null) {
      final maskSrc = Rect.fromLTWH(
        0,
        0,
        mask.width.toDouble(),
        mask.height.toDouble(),
      );
      canvas.drawImageRect(
        mask,
        maskSrc,
        dest,
        Paint()..blendMode = BlendMode.dstOut,
      );
    }

    canvas.restore();

    // 3) Prompt points.
    if (points.isNotEmpty) {
      final r = layout.destRect;
      final scale = layout.scale;
      for (final p in points) {
        final dx = r.left + p.x * scale;
        final dy = r.top + p.y * scale;
        final center = Offset(dx, dy);
        final fill = Paint()
          ..style = PaintingStyle.fill
          ..color = (p.label == 1 ? Colors.green : Colors.red)
              .withValues(alpha: 0.85);
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = theme.colorScheme.onSurface.withValues(alpha: 0.85);
        canvas.drawCircle(center, 5, fill);
        canvas.drawCircle(center, 5, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentationPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.maskAlpha != maskAlpha ||
        oldDelegate.points != points ||
        oldDelegate.dimFactor != dimFactor ||
        oldDelegate.theme != theme;
  }
}
