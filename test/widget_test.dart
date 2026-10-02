import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/src/app.dart';

void main() {
  testWidgets('shows the four phone and PC library destinations', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NexGalleryApp(platform: TargetPlatform.android),
    );

    for (final label in ['Photos', 'Library', 'My PC', 'Files']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Your moments, kept private'), findsOneWidget);
    expect(find.text('PLANNED'), findsNWidgets(3));
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);

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

    await tester.pumpWidget(
      const NexGalleryApp(platform: TargetPlatform.windows),
    );
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('This PC'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Your local media workspace'), findsOneWidget);
  });

  testWidgets('fits a compact 320 by 568 phone without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const NexGalleryApp(platform: TargetPlatform.android),
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Local first'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
