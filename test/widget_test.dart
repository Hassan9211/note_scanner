// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:note_scanner/main.dart';

void main() {
  testWidgets('shows the empty camera state', (WidgetTester tester) async {
    await tester.pumpWidget(const NoteScannerApp(cameras: []));
    await tester.pump();

    expect(find.text('Currency Note Checker'), findsOneWidget);
    expect(find.text('Camera not available'), findsOneWidget);
    expect(find.text('No camera found on this device.'), findsOneWidget);

    final scanButton = tester.widget<ElevatedButton>(
      find.byType(ElevatedButton),
    );
    expect(scanButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
