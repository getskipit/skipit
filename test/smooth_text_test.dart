import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/smooth_text.dart';

void main() {
  setUpAll(() async {
    final loader = FontLoader('Segoe UI');
    loader.addFont(Future.value(ByteData.sublistView(await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())));
    await loader.load();
  });

  testWidgets('sampled text preserves layout, baseline and its click target', (tester) async {
    var clicks = 0;
    final normal = GlobalKey(), smooth = GlobalKey();
    const style = TextStyle(fontFamily: 'Segoe UI', fontSize: 28, fontWeight: FontWeight.w600);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic,
      children: [
        Text('ЗАЩИЩЕНО', key: normal, style: style),
        GestureDetector(onTap: () => clicks++,
          child: SmoothText('ЗАЩИЩЕНО', key: smooth, style: style)),
      ],
    ))));
    final a = tester.getSize(find.byKey(normal));
    final b = tester.getSize(find.byKey(smooth));
    expect(b.width, closeTo(a.width, 2));
    expect(b.height, closeTo(a.height, 2));
    final baselineA = (normal.currentContext!.findRenderObject() as RenderBox).getDryBaseline(const BoxConstraints(), TextBaseline.alphabetic)!;
    final baselineB = (smooth.currentContext!.findRenderObject() as RenderBox).getDryBaseline(const BoxConstraints(), TextBaseline.alphabetic)!;
    expect(baselineB, closeTo(baselineA, 2));
    await tester.tapAt(tester.getCenter(find.byKey(smooth)));
    expect(clicks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sampled heading respects width, intrinsic layout and text scaling', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
      child: Center(child: SizedBox(width: 180, child: IntrinsicHeight(child: Row(children: [
        Expanded(child: SmoothText('Connection diagnostics', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700))),
      ])))),
    ))));
    expect(tester.getSize(find.byType(SmoothText)).width, 180);
    expect(tester.takeException(), isNull);
  });
}
