from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    target = Path(path)
    data = target.read_text()
    count = data.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}")
    target.write_text(data.replace(old, new))


repo = "casla_production/lib/data/repositories/repositories_impl.dart"
replace(
    repo,
    "import '../../core/database/casla_database.dart';\n",
    "import '../../core/database/casla_database.dart';\nimport '../../core/telemetry/field_telemetry.dart';\n",
)
replace(
    repo,
    """  final WorkHistoryLoader loadRemote;
  final String? Function() cacheSubject;
  final Duration freshFor;
  final DateTime Function() _now;

  final Map<String, Future<WorkHistoryResult>> _inFlight = {};

  WorkHistoryRepositoryImpl(
    this.db, {
    required this.loadRemote,
    required this.cacheSubject,
    this.freshFor = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
""",
    """  final WorkHistoryLoader loadRemote;
  final String? Function() cacheSubject;
  final Duration freshFor;
  final FieldTelemetry telemetry;
  final DateTime Function() _now;

  final Map<String, Future<WorkHistoryResult>> _inFlight = {};

  WorkHistoryRepositoryImpl(
    this.db, {
    required this.loadRemote,
    required this.cacheSubject,
    this.freshFor = const Duration(minutes: 2),
    FieldTelemetry? telemetry,
    DateTime Function()? now,
  }) : telemetry = telemetry ?? FieldTelemetry.instance,
       _now = now ?? DateTime.now;
""",
)
replace(
    repo,
    """    if (subject == null || subject.isEmpty) {
      return loadRemote(range: range, dateFrom: dateFrom, dateTo: dateTo);
    }
""",
    """    if (subject == null || subject.isEmpty) {
      final stopwatch = Stopwatch()..start();
      try {
        final result = await loadRemote(
          range: range,
          dateFrom: dateFrom,
          dateTo: dateTo,
        );
        stopwatch.stop();
        telemetry.recordDuration(
          FieldMetric.workHistoryRemoteSuccess,
          stopwatch.elapsed,
        );
        return result;
      } catch (_) {
        stopwatch.stop();
        telemetry.recordDuration(
          FieldMetric.workHistoryRemoteFailure,
          stopwatch.elapsed,
        );
        rethrow;
      }
    }
""",
)
replace(
    repo,
    """    final cached = await _readCache(cacheKey);
    if (cached != null) {
      final age = _now().difference(cached.fetchedAt);
      if (age >= freshFor) {
        unawaited(
          _ignoreRefreshFailure(
            _refresh(
              cacheKey: cacheKey,
              subject: subject,
              range: range,
              dateFrom: dateFrom,
              dateTo: dateTo,
            ),
          ),
        );
      }
      return cached.result;
    }

    return _refresh(
""",
    """    final cached = await _readCache(cacheKey);
    if (cached != null) {
      final age = _now().difference(cached.fetchedAt);
      if (age >= freshFor) {
        telemetry.increment(FieldMetric.workHistoryStaleHit);
        unawaited(
          _ignoreRefreshFailure(
            _refresh(
              cacheKey: cacheKey,
              subject: subject,
              range: range,
              dateFrom: dateFrom,
              dateTo: dateTo,
            ),
          ),
        );
      } else {
        telemetry.increment(FieldMetric.workHistoryCacheHit);
      }
      return cached.result;
    }

    telemetry.increment(FieldMetric.workHistoryCacheMiss);
    return _refresh(
""",
)
replace(
    repo,
    """    final result = await loadRemote(
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
    final fetchedAt = _now();
""",
    """    final stopwatch = Stopwatch()..start();
    late final WorkHistoryResult result;
    try {
      result = await loadRemote(
        range: range,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );
      stopwatch.stop();
      telemetry.recordDuration(
        FieldMetric.workHistoryRemoteSuccess,
        stopwatch.elapsed,
      );
    } catch (_) {
      stopwatch.stop();
      telemetry.recordDuration(
        FieldMetric.workHistoryRemoteFailure,
        stopwatch.elapsed,
      );
      rethrow;
    }
    final fetchedAt = _now();
""",
)

scanner = "casla_production/lib/presentation/widgets/adaptive_barcode_scanner_view.dart"
replace(
    scanner,
    "import '../../core/scanner/scan_deduplicator.dart';\n",
    "import '../../core/scanner/scan_deduplicator.dart';\nimport '../../core/telemetry/field_telemetry.dart';\n",
)
replace(
    scanner,
    """  final FutureOr<void> Function(String code) onScan;
  final BarcodeScanner? hardwareScanner;

  const AdaptiveBarcodeScannerView({
""",
    """  final FutureOr<void> Function(String code) onScan;
  final BarcodeScanner? hardwareScanner;
  final FieldTelemetry? telemetry;

  const AdaptiveBarcodeScannerView({
""",
)
replace(
    scanner,
    """    this.onManualInput,
    this.hardwareScanner,
  });
""",
    """    this.onManualInput,
    this.hardwareScanner,
    this.telemetry,
  });
""",
)
replace(
    scanner,
    """  final ScanDeduplicator _deduplicator = ScanDeduplicator();

  StreamSubscription<BarcodeScanEvent>? _scanSubscription;
""",
    """  final ScanDeduplicator _deduplicator = ScanDeduplicator();

  FieldTelemetry get _telemetry => widget.telemetry ?? FieldTelemetry.instance;

  StreamSubscription<BarcodeScanEvent>? _scanSubscription;
""",
)
replace(
    scanner,
    """    final code = event.rawValue.trim();
    if (code.isEmpty || !_deduplicator.shouldAccept(code)) return;

    _isHandlingScan = true;
""",
    """    final code = event.rawValue.trim();
    if (code.isEmpty) return;
    if (!_deduplicator.shouldAccept(code)) {
      _telemetry.increment(FieldMetric.hardwareScanDuplicate);
      return;
    }

    _telemetry.increment(FieldMetric.hardwareScanAccepted);
    _isHandlingScan = true;
""",
)

history = "casla_production/lib/features/worker/screens/w01_history_screen.dart"
replace(
    history,
    """class _W01HistoryScreenState extends ConsumerState<W01HistoryScreen> {
  HistoryRange _range = HistoryRange.month;
""",
    """class _W01HistoryScreenState extends ConsumerState<W01HistoryScreen> {
  static const int _historyEntryPageSize = 50;

  HistoryRange _range = HistoryRange.month;
""",
)
replace(
    history,
    """  DateTime? _customDateTo;
  late Future<WorkHistoryResult> _future;
""",
    """  DateTime? _customDateTo;
  late Future<WorkHistoryResult> _future;
  int _visibleEntryCount = _historyEntryPageSize;
""",
)
replace(
    history,
    """    setState(() {
      _range = range;
      _future = _load();
    });
""",
    """    setState(() {
      _range = range;
      _visibleEntryCount = _historyEntryPageSize;
      _future = _load();
    });
""",
)
replace(
    history,
    """      if (!mounted) return;
      setState(() => _future = Future.value(result));
""",
    """      if (!mounted) return;
      setState(() {
        _visibleEntryCount = _historyEntryPageSize;
        _future = Future.value(result);
      });
""",
)
replace(
    history,
    """      _customDateFrom = DateTime(picked.year, picked.month, picked.day);
      _customDateTo = DateTime(picked.year, picked.month, picked.day);
      _future = _load();
""",
    """      _customDateFrom = DateTime(picked.year, picked.month, picked.day);
      _customDateTo = DateTime(picked.year, picked.month, picked.day);
      _visibleEntryCount = _historyEntryPageSize;
      _future = _load();
""",
)
replace(
    history,
    """      _customDateTo = DateTime(
        picked.end.year,
        picked.end.month,
        picked.end.day,
      );
      _future = _load();
""",
    """      _customDateTo = DateTime(
        picked.end.year,
        picked.end.month,
        picked.end.day,
      );
      _visibleEntryCount = _historyEntryPageSize;
      _future = _load();
""",
)
replace(
    history,
    """  Widget _buildContent(WorkHistoryResult result) {
    return Column(
""",
    """  Widget _buildContent(WorkHistoryResult result) {
    final visibleCount = _visibleEntryCount < result.entries.length
        ? _visibleEntryCount
        : result.entries.length;
    final visibleEntries = result.entries.take(visibleCount).toList(
      growable: false,
    );

    return Column(
""",
)
replace(
    history,
    """              itemCount: result.entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildEntryTile(result.entries[index]),
            ),
          ),
      ],
""",
    """              itemCount: visibleEntries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildEntryTile(visibleEntries[index]),
            ),
          ),
        if (visibleEntries.length < result.entries.length) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              key: const Key('history-load-more'),
              onPressed: () {
                setState(() {
                  final next = _visibleEntryCount + _historyEntryPageSize;
                  _visibleEntryCount = next < result.entries.length
                      ? next
                      : result.entries.length;
                });
              },
              icon: const Icon(Icons.expand_more_rounded),
              label: Text(
                'Xem thêm • ${visibleEntries.length}/${result.entries.length} giao dịch',
              ),
            ),
          ),
        ],
      ],
""",
)

scanner_test = "casla_production/test/presentation/adaptive_barcode_scanner_view_test.dart"
replace(
    scanner_test,
    "import 'package:casla_production/core/scanner/barcode_scanner.dart';\n",
    "import 'package:casla_production/core/scanner/barcode_scanner.dart';\nimport 'package:casla_production/core/telemetry/field_telemetry.dart';\n",
)
replace(
    scanner_test,
    """    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    final accepted = <String>[];
""",
    """    final scanner = _FakeScanner(available: true);
    final telemetry = FieldTelemetry();
    addTearDown(scanner.close);
    final accepted = <String>[];
""",
)
replace(
    scanner_test,
    """            hardwareScanner: scanner,
            onScan: accepted.add,
""",
    """            hardwareScanner: scanner,
            telemetry: telemetry,
            onScan: accepted.add,
""",
)
replace(
    scanner_test,
    """    expect(accepted, ['MNV00123']);
    expect(find.text('ĐÃ NHẬN MÃ'), findsOneWidget);
    expect(find.text('Đã nhận mã • đang kiểm tra dữ liệu'), findsOneWidget);

    scanner.emit('MNV00123');
    await tester.pump();
    expect(accepted, ['MNV00123']);

    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('SẴN SÀNG QUÉT'), findsOneWidget);
    expect(find.text('Sẵn sàng cho lượt quét tiếp theo'), findsOneWidget);
""",
    """    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanAccepted), 1);
    expect(find.text('ĐÃ NHẬN MÃ'), findsOneWidget);
    expect(find.text('Đã nhận mã • đang kiểm tra dữ liệu'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('SẴN SÀNG QUÉT'), findsOneWidget);
    expect(find.text('Sẵn sàng cho lượt quét tiếp theo'), findsOneWidget);

    scanner.emit('MNV00123');
    await tester.pump();
    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanDuplicate), 1);
""",
)

cache_test = "casla_production/test/data/work_history_cache_repository_test.dart"
replace(
    cache_test,
    "import 'package:casla_production/core/database/casla_database.dart';\n",
    "import 'package:casla_production/core/database/casla_database.dart';\nimport 'package:casla_production/core/telemetry/field_telemetry.dart';\n",
)
replace(
    cache_test,
    """  test('fresh cache avoids a second SAP call', () async {
    var calls = 0;
    final now = DateTime(2026, 9, 4, 12);
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
""",
    """  test('fresh cache avoids a second SAP call', () async {
    var calls = 0;
    final now = DateTime(2026, 9, 4, 12);
    final telemetry = FieldTelemetry();
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      telemetry: telemetry,
""",
)
replace(
    cache_test,
    """    expect(calls, 1);
    expect(first.workers.single.workerName, 'Nguyễn Văn A');
    expect(second.workers.single.workerName, 'Nguyễn Văn A');
  });
""",
    """    expect(calls, 1);
    expect(first.workers.single.workerName, 'Nguyễn Văn A');
    expect(second.workers.single.workerName, 'Nguyễn Văn A');
    final metrics = telemetry.snapshot();
    expect(metrics.count(FieldMetric.workHistoryCacheMiss), 1);
    expect(metrics.count(FieldMetric.workHistoryCacheHit), 1);
    expect(metrics.count(FieldMetric.workHistoryRemoteSuccess), 1);
  });
""",
)
replace(
    cache_test,
    """  test('cache namespace prevents cross-account history reuse', () async {
""",
    """  test('remote failures are counted without recording request data', () async {
    final telemetry = FieldTelemetry();
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      telemetry: telemetry,
      loadRemote: ({required range, dateFrom, dateTo}) async {
        throw Exception('offline');
      },
    );

    await expectLater(
      repo.getWorkHistory(range: HistoryRange.day),
      throwsException,
    );

    final snapshot = telemetry.snapshot();
    final diagnostics = snapshot.toDiagnosticMap();
    expect(snapshot.count(FieldMetric.workHistoryCacheMiss), 1);
    expect(snapshot.count(FieldMetric.workHistoryRemoteFailure), 1);
    expect(diagnostics.toString(), isNot(contains('user-a')));
    expect(diagnostics.toString(), isNot(contains('offline')));
  });

  test('cache namespace prevents cross-account history reuse', () async {
""",
)
