import 'package:casla_production/presentation/widgets/num_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('allows a fractional production quantity', (tester) async {
    String value = '1';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => NumPad(
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('num-pad-key-.')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('num-pad-key-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('num-pad-key-5')));
    await tester.pump();

    expect(value, '1.25');
  });
}
