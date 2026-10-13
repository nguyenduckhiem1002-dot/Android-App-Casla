import '../utils/operation_qr_parser.dart';
import '../utils/worker_qr_parser.dart';
import 'scan_diagnostics.dart';

enum ScannedCodeKind { operation, worker, unknown }

/// One scanned payload, already classified.
class ScannedCode {
  final ScannedCodeKind kind;
  final String rawValue;
  final OperationQrResult? operation;
  final WorkerQrResult? worker;

  const ScannedCode._({
    required this.kind,
    required this.rawValue,
    this.operation,
    this.worker,
  });

  bool get isOperation => kind == ScannedCodeKind.operation;

  bool get isWorker => kind == ScannedCodeKind.worker;

  /// Message to show when nothing could be made of the payload. Prefers the
  /// worker parser's reason, because a mis-scan on a worker card is the more
  /// common way an operator lands here.
  String get error =>
      worker?.error ?? operation?.error ?? 'Mã QR không đúng định dạng.';
}

/// Decides what a scanned payload is, so a screen can accept a trigger pull
/// without first asking the operator which field they are about to fill.
///
/// This is what makes the laser-first flow possible: pull the trigger at the
/// operation label, pull it again at the worker card, done. No taps, no
/// full-screen scanner route in between.
class ScanClassifier {
  ScanClassifier._();

  /// Operation first, deliberately.
  ///
  /// [OperationQrParser] is the strict one: it needs a production order plus an
  /// operation number, either as named fields or as an explicitly delimited
  /// pair. [WorkerQrParser] ends in a bare-string fallback that accepts almost
  /// any short token, so asking it first would let it swallow operation codes.
  static ScannedCode classify(String rawValue) {
    final code = rawValue.trim();
    if (code.isEmpty) {
      return const ScannedCode._(kind: ScannedCodeKind.unknown, rawValue: '');
    }

    final operation = OperationQrParser.parse(code);
    final worker = WorkerQrParser.parse(code);
    ScanDiagnostics.instance.record(
      operation.isValid
          ? ScanDiagnosticEvent.classifiedOperation
          : worker.isValid
          ? ScanDiagnosticEvent.classifiedWorker
          : ScanDiagnosticEvent.classifiedUnknown,
      length: code.length,
    );
    if (operation.isValid) {
      return ScannedCode._(
        kind: ScannedCodeKind.operation,
        rawValue: code,
        operation: operation,
      );
    }

    if (worker.isValid) {
      return ScannedCode._(
        kind: ScannedCodeKind.worker,
        rawValue: code,
        worker: worker,
      );
    }

    return ScannedCode._(
      kind: ScannedCodeKind.unknown,
      rawValue: code,
      operation: operation,
      worker: worker,
    );
  }

  /// True when the payload has the shape of a retail product barcode.
  ///
  /// A laser grabs whatever is in front of it, and a carton label sitting next
  /// to a worker card is the classic mis-scan. Employee codes in this system
  /// are short, or mixed letters and digits, or prefixed — never a bare
  /// EAN-8/UPC-A/EAN-13/ITF-14 digit run.
  ///
  /// Used to sharpen the warning before an unknown worker is created, never to
  /// reject on its own: a site that really does issue 13-digit numeric badges
  /// must still be able to confirm and carry on.
  static bool looksLikeRetailBarcode(String value) {
    final code = value.trim();
    const retailLengths = {8, 12, 13, 14};
    if (!retailLengths.contains(code.length)) return false;
    return RegExp(r'^\d+$').hasMatch(code);
  }
}
