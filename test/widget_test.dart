import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/src/app.dart';

void main() {
  testWidgets('shows the four phone and PC library destinations', (
    tester,
  ) async {
    await tester.pumpWidget(const NexGalleryApp());

    for (final label in ['Photos', 'Library', 'My PC', 'Files']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Photos on this phone'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.computer_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Your PC, anywhere'), findsOneWidget);
    expect(find.byIcon(Icons.computer_rounded), findsWidgets);
  });

  testWidgets('uses desktop navigation at wide widths', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const NexGalleryApp());
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
