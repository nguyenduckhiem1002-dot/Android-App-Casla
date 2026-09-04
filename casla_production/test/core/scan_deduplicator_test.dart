import 'package:casla_production/core/scanner/scan_deduplicator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('suppresses the same scan inside the debounce window', () {
    final deduplicator = ScanDeduplicator(
      window: const Duration(milliseconds: 750),
    );
    final t0 = DateTime(2026, 9, 4, 12);

    expect(deduplicator.shouldAccept(' NV00123 ', now: t0), isTrue);
    expect(
      deduplicator.shouldAccept(
        'NV00123',
        now: t0.add(const Duration(milliseconds: 500)),
      ),
      isFalse,
    );
    expect(
      deduplicator.shouldAccept(
        'NV00123',
        now: t0.add(const Duration(milliseconds: 751)),
      ),
      isTrue,
    );
  });

  test('accepts a different barcode immediately', () {
    final deduplicator = ScanDeduplicator();
    final t0 = DateTime(2026, 9, 4, 12);

    expect(deduplicator.shouldAccept('NV00123', now: t0), isTrue);
    expect(
      deduplicator.shouldAccept(
        'NV00124',
        now: t0.add(const Duration(milliseconds: 10)),
      ),
      isTrue,
    );
  });
}
