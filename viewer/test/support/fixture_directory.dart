import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deletes only a directory allocated by its test. Cleanup errors fail the test.
Future<void> removeFixtureDirectory(Directory root) async {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  root.deleteSync(recursive: true);
}

/// Dimensions can arrive before FileImage decoding releases its source buffer.
Future<void> waitForFixtureImages(WidgetTester tester) async {
  final images = tester.elementList(find.byType(Image)).toList();
  expect(images, isNotEmpty);
  for (final element in images) {
    final image = element.widget as Image;
    await tester.runAsync(() => precacheImage(image.image, element));
  }
  // precacheImage drops its extra listener at the end of this frame.
  await tester.pump();
}
