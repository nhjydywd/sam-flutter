import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'segmentation_preview.dart';

class MaskedCutoutPreview extends StatelessWidget {
  const MaskedCutoutPreview({
    super.key,
    required this.image,
    required this.maskAlpha,
    this.backgroundColor,
    this.onAddPoint,
    this.onHoverImagePx,
    this.onExit,
  });

  final ui.Image image;
  final ui.Image? maskAlpha;
  final Color? backgroundColor;
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
              painter: _MaskedCutoutPainter(
                image: image,
                maskAlpha: maskAlpha,
                backgroundColor:
                    backgroundColor ?? Theme.of(context).colorScheme.surface,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _MaskedCutoutPainter extends CustomPainter {
  _MaskedCutoutPainter({
    required this.image,
    required this.maskAlpha,
    required this.backgroundColor,
  });

  final ui.Image image;
  final ui.Image? maskAlpha;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);

    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    if (iw <= 0 || ih <= 0 || size.width <= 0 || size.height <= 0) return;

    final s = math.min(size.width / iw, size.height / ih);
    final dw = iw * s;
    final dh = ih * s;
    final dx = (size.width - dw) / 2.0;
    final dy = (size.height - dh) / 2.0;
    final dest = Rect.fromLTWH(dx, dy, dw, dh);
    final src = Rect.fromLTWH(0, 0, iw, ih);

    final mask = maskAlpha;
    if (mask == null) {
      return; // no result yet
    }

    final maskSrc = Rect.fromLTWH(
      0,
      0,
      mask.width.toDouble(),
      mask.height.toDouble(),
    );

    final layerRect = dest.inflate(1);
    canvas.saveLayer(layerRect, Paint());
    canvas.drawImageRect(image, src, dest, Paint());
    canvas.drawImageRect(
        mask, maskSrc, dest, Paint()..blendMode = BlendMode.dstIn);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MaskedCutoutPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.maskAlpha != maskAlpha ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
