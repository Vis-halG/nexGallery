import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/data/device/device_bridge.dart';
import 'package:nex_gallery/features/common/dialogs.dart';

void main() {
  const channel = MethodChannel('test/device');
  final device = DeviceBridge(channel: channel, isAndroid: true);

  Future<bool?> run(
    WidgetTester tester,
    String? reply, {
    bool tap = true,
  }) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return reply;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await confirmIrreversible(
              context,
              title: 'Empty Trash?',
              message: 'This cannot be undone.',
              action: 'Empty Trash',
              device: device,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('This cannot be undone.'), findsOneWidget);
    await tester.tap(find.text(tap ? 'Empty Trash' : 'Cancel'));
    await tester.pumpAndSettle();
    expect(calls.length, tap ? 1 : 0);
    if (tap) expect(calls.single.method, 'confirmUser');
    return result;
  }

  testWidgets('a confirmed fingerprint or PIN continues', (tester) async {
    expect(await run(tester, 'success'), isTrue);
  });

  testWidgets('cancelling the screen-lock check stops the action', (
    tester,
  ) async {
    expect(await run(tester, 'cancelled'), isFalse);
  });

  testWidgets('a phone without a screen lock relies on the dialog', (
    tester,
  ) async {
    expect(await run(tester, 'notSecured'), isTrue);
  });

  testWidgets('cancelling the dialog never asks for the PIN', (tester) async {
    expect(await run(tester, 'success', tap: false), isFalse);
  });
}
