import 'package:casla_production/app/theme/casla_colors.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/local_history_overlay.dart';
import 'package:casla_production/domain/policies/unit_totals.dart';
import 'package:casla_production/presentation/widgets/worker_totals_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _units = [
  UnitTotals(
    unit: 'CHC',
    given: 2033,
    completed: 115,
    recalled: 0,
    remaining: 1918,
  ),
  UnitTotals(
    unit: 'BOO',
    given: 600,
    completed: 240,
    recalled: 40,
    remaining: 320,
  ),
  UnitTotals(
    unit: 'CAI',
    given: 150,
    completed: 150,
    recalled: 0,
    remaining: 0,
  ),
];

Future<void> pump(WidgetTester tester, List<UnitTotals> units) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 393, child: WorkerTotalsHeader(units: units)),
        ),
      ),
    );

String scope(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('worker-totals-scope')))
    .data!;

void main() {
  Color figureColor(WidgetTester tester, String value) =>
      tester.widget<Text>(find.text(value)).style!.color!;

  testWidgets('scrap has its own figure, in deep yellow when there is some', (
    tester,
  ) async {
    // Given 50.000, 50.001 good and 20 scrapped: 21 over what was given.
    await pump(tester, const [
      UnitTotals(
        unit: 'CHC',
        given: 50000,
        completed: 50001,
        defect: 20,
        recalled: 0,
        remaining: -21,
      ),
    ]);

    expect(find.text('Phế'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(figureColor(tester, '20'), CaslaColors.scrap);
    expect(find.text('50.001'), findsOneWidget);
    expect(find.text('-21'), findsOneWidget);
    // No rate: only the quantity is shown.
    expect(find.textContaining('%'), findsOneWidget); // the completion rate
    expect(find.textContaining('sản lượng đã làm'), findsNothing);
  });

  testWidgets('with no scrap the figure reads 0 and stays quiet', (
    tester,
  ) async {
    await pump(tester, const [
      UnitTotals(
        unit: 'CHC',
        given: 500,
        completed: 320,
        recalled: 10,
        remaining: 170,
      ),
    ]);

    expect(find.text('Phế'), findsOneWidget);
    expect(figureColor(tester, '0'), CaslaColors.muted);
  });

  testWidgets('"Tất cả" adds every unit; a chip narrows to one unit', (
    tester,
  ) async {
    await pump(tester, _units);

    // All units: 2033 + 600 + 150 given, 505 done, 40 recalled.
    expect(find.text('2.783'), findsOneWidget);
    expect(find.text('505'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('2.238'), findsOneWidget);
    expect(find.text('18%'), findsOneWidget); // 505 / (2783 - 40)
    expect(scope(tester), contains('3 đơn vị'));

    await tester.tap(find.byKey(const ValueKey('unit-chip-BOO')));
    await tester.pump();
    expect(find.text('240'), findsOneWidget);
    expect(find.text('320'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget); // 240 / (600 - 40), rounded down
    expect(scope(tester), 'Đơn vị: BOO');

    await tester.tap(find.byKey(const ValueKey('unit-chip-all')));
    await tester.pump();
    expect(find.text('2.783'), findsOneWidget);
  });

  testWidgets('shows 99% and a filled bar while 10 of 2.410 remain', (
    tester,
  ) async {
    const almost = UnitTotals(
      unit: 'CHC',
      given: 2500,
      completed: 2400,
      recalled: 90,
      remaining: 10,
    );
    await pump(tester, [almost]);

    // 2400 / (2500 - 90) = 99.59%: not finished, so never 100%.
    expect(find.text('99%'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    // Every segment of the stacked bar is drawn at the bar's full height.
    // The bar's grey track is a ColoredBox too, but it holds the segments.
    final segments = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.child == null,
    );
    expect(segments, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(segments.at(i)).height, 10);
    }
    final done = tester.getSize(segments.first).width;
    expect(done, greaterThan(tester.getSize(segments.at(1)).width));

    await pump(tester, [
      const UnitTotals(
        unit: 'CHC',
        given: 2500,
        completed: 2410,
        recalled: 90,
        remaining: 0,
      ),
    ]);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('nothing left reads 100% despite fractions hidden by rounding', (
    tester,
  ) async {
    // Shown as 7.200 · 4.700 · 2.500 · 0 CHC; the raw 2499.6 / 2500.4
    // would otherwise round down to 99%.
    await pump(tester, [
      const UnitTotals(
        unit: 'CHC',
        given: 7200.4,
        completed: 2499.6,
        recalled: 4700,
        remaining: 0,
      ),
    ]);
    expect(find.text('2.500'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    // A remaining that still shows as 0 counts as nothing left too.
    await pump(tester, [
      const UnitTotals(
        unit: 'CHC',
        given: 7200,
        completed: 2499.7,
        recalled: 4700,
        remaining: 0.3,
      ),
    ]);
    expect(find.text('100%'), findsOneWidget);

    // Fully recalled: nothing was finished, so it stays 0%.
    await pump(tester, [
      const UnitTotals(
        unit: 'CHC',
        given: 900,
        completed: 0,
        recalled: 900,
        remaining: 0,
      ),
    ]);
    expect(find.text('0%'), findsOneWidget);
  });

  testWidgets('a single unit shows no chips', (tester) async {
    await pump(tester, [_units.first]);
    expect(find.byKey(const ValueKey('unit-chip-all')), findsNothing);
    expect(find.text('2.033'), findsOneWidget);
    expect(scope(tester), 'Đơn vị: CHC');
  });

  testWidgets('fits a 320dp screen with enlarged text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const Scaffold(
          body: SizedBox(width: 320, child: WorkerTotalsHeader(units: _units)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('per-unit figures apply only the pending rows of that unit', () {
    WorkHistorySummary row(String workId, String unit, double given) =>
        WorkHistorySummary(
          workerId: 'NV01',
          workerName: 'A',
          assignedQuantity: given,
          completedQuantity: 0,
          remainingQuantity: given,
          unitOfMeasure: unit,
          transactionCount: 1,
          workId: workId,
        );
    LocalLedgerRow pending(LocalLedgerKind kind, double qty, String unit) =>
        LocalLedgerRow(
          kind: kind,
          workerId: 'emp-1',
          workerCode: 'NV01',
          quantity: qty,
          unit: unit,
          syncStatus: 'PENDING',
          idempotencyKey: 'k-$kind-$unit-$qty',
        );

    final totals = workerUnitTotalsFromSap(
      // CHC split over two WorkIDs, as SAP reports carried-over work.
      sapRows: [row('A', 'CHC', 1418), row('B', 'CHC', 1), row('A', 'BOO', 50)],
      workerKeys: const ['emp-1', 'NV01'],
      pending: buildLocalPendingLedger(
        sap: null,
        rows: [
          pending(LocalLedgerKind.confirm, 10, 'CHC'),
          pending(LocalLedgerKind.recall, 5, 'BOO'),
          // A unit SAP has not reported for this worker yet.
          pending(LocalLedgerKind.assign, 7, 'CAI'),
        ],
      ),
    );

    final byUnit = {for (final t in totals) t.unit.toUpperCase(): t};
    expect(byUnit['CHC']!.given, 1419);
    expect(byUnit['CHC']!.completed, 10);
    expect(byUnit['CHC']!.remaining, 1419 - 10);
    expect(byUnit['BOO']!.recalled, 5);
    expect(byUnit['BOO']!.remaining, 45);
    expect(byUnit['CAI']!.given, 7);
    expect(totals.first.unit, 'CHC', reason: 'largest given first');
  });
}
