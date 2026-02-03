import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'segmentation_preview.dart';

class ImageWithPromptsPreview extends StatelessWidget {
  const ImageWithPromptsPreview({
    super.key,
    required this.image,
    this.points = const <PromptPoint>[],
    this.hoverPoint,
    this.onAddPoint,
    this.onHoverImagePx,
    this.onExit,
  });

  final ui.Image image;
  final List<PromptPoint> points;
  final PromptPoint? hoverPoint;
  final void Function(PromptPoint point)? onAddPoint;
  final void Function(Offset imagePx)? onHoverImagePx;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return MouseRegion(
          onExit: onExit == null ? null : (_) => onExit!(),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerHover: onHoverImagePx == null
                ? null
                : (event) {
                    final mapped = mapLocalToImagePx(
                      localPosition: event.localPosition,
                      canvasSize: size,
                      imageWidth: image.width,
                      imageHeight: image.height,
                    );
                    if (mapped == null) return;
                    onHoverImagePx!(mapped);
                  },
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
              painter: _ImageWithPromptsPainter(
                image: image,
                points: points,
                hoverPoint: hoverPoint,
                theme: Theme.of(context),
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _ImageWithPromptsPainter extends CustomPainter {
  _ImageWithPromptsPainter({
    required this.image,
    required this.points,
    required this.hoverPoint,
    required this.theme,
  });

  final ui.Image image;
  final List<PromptPoint> points;
  final PromptPoint? hoverPoint;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    if (iw <= 0 || ih <= 0 || size.width <= 0 || size.height <= 0) return;

    final scale = math.min(size.width / iw, size.height / ih);
    final dw = iw * scale;
    final dh = ih * scale;
    final dx = (size.width - dw) / 2.0;
    final dy = (size.height - dh) / 2.0;
    final dest = Rect.fromLTWH(dx, dy, dw, dh);
    final src = Rect.fromLTWH(0, 0, iw, ih);

    canvas.drawImageRect(image, src, dest, Paint());

    if (points.isNotEmpty || hoverPoint != null) {
      for (final p in points) {
        final cx = dx + p.x * scale;
        final cy = dy + p.y * scale;
        final center = Offset(cx, cy);
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

      final hp = hoverPoint;
      if (hp != null) {
        final cx = dx + hp.x * scale;
        final cy = dy + hp.y * scale;
        final center = Offset(cx, cy);
        final fill = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.green.withValues(alpha: 0.45);
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.green.withValues(alpha: 0.85);
        canvas.drawCircle(center, 7, fill);
        canvas.drawCircle(center, 7, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ImageWithPromptsPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.points != points ||
        oldDelegate.hoverPoint != hoverPoint ||
        oldDelegate.theme != theme;
  }
}
