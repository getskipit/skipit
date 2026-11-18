import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'theme.dart';

const iconPreviewSize = 30.0;
const iconPreviewCell = 32.0;
const iconPreviewAsset = 'assets/icon_previews.png';
const iconPreviewAtlas = AssetImage(iconPreviewAsset);

/// Готовая миниатюра из листа, нарисованного SkipItIconPainter (tools/make_icon_previews_test.dart).
class IconStylePreview extends StatelessWidget {
  const IconStylePreview({super.key, required this.style, required this.accent});

  final IconStyle style;
  final Accent accent;

  @override
  Widget build(BuildContext context) {
    const padding = (iconPreviewCell - iconPreviewSize) / 2;
    return SizedBox.square(
      dimension: iconPreviewSize,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: -((style.index - 1) * iconPreviewCell + padding),
            top: -(accent.index * iconPreviewCell + padding),
            width: (IconStyle.values.length - 1) * iconPreviewCell,
            height: Accent.values.length * iconPreviewCell,
            child: const Image(image: iconPreviewAtlas, filterQuality: FilterQuality.low),
          ),
        ],
      ),
    );
  }
}
