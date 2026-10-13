import 'dart:convert';

/// Tolerant reading of JSON payloads that arrive through a barcode reader.
///
/// The labels themselves are well-formed JSON printed by SAP. What breaks them
/// is the path to the app: a reader prefixes an AIM symbology id (`]Q1`) or
/// appends a GS/CR, a double trigger glues two payloads together, a vendor
/// service decodes UTF-8 bytes as Latin-1/Windows-1252, or a label generator
/// emits raw line breaks and trailing commas. Each repair below is applied only
/// when plain decoding fails, and never invents field values.
class ScannedJson {
  ScannedJson._();

  /// Removes invisible characters and undoes UTF-8 read as Latin-1/CP1252
  /// ("KÃ©o sá»£i" → "Kéo sợi"). Text that is already correct is returned
  /// unchanged: the repair only applies when the result is valid UTF-8.
  static String normalizeText(String value) {
    final cleaned = value.replaceAll(RegExp('[​‌‍⁠﻿]'), '');
    return _repairMojibake(cleaned);
  }

  /// Decodes the first JSON object found in [input].
  ///
  /// [ScannedJsonResult.attempted] is true when the payload contains a `{`, so
  /// a caller can tell "not JSON" from "JSON that arrived damaged" (usually a
  /// partial read) and ask for a rescan instead of a generic error.
  static ScannedJsonResult decodeObject(String input) {
    final start = input.indexOf('{');
    if (start < 0) return const ScannedJsonResult(attempted: false);
    final objectText = _firstBalancedObject(input, start);
    if (objectText == null) return const ScannedJsonResult(attempted: true);

    for (final candidate in _repairCandidates(objectText)) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return ScannedJsonResult(attempted: true, fields: _flatten(decoded));
        }
        return const ScannedJsonResult(attempted: true);
      } on FormatException {
        continue;
      }
    }
    return const ScannedJsonResult(attempted: true);
  }

  /// The object starting at [start], ending at its matching brace. Text before
  /// it (a symbology prefix) and after it (a suffix, or a second glued scan)
  /// is ignored. Null when the object never closes — a truncated read.
  static String? _firstBalancedObject(String input, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < input.length; i++) {
      final char = input.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == 0x5C) {
          escaped = true;
        } else if (char == 0x22) {
          inString = false;
        }
        continue;
      }
      if (char == 0x22) {
        inString = true;
      } else if (char == 0x7B) {
        depth++;
      } else if (char == 0x7D) {
        depth--;
        if (depth == 0) return input.substring(start, i + 1);
      }
    }
    return null;
  }

  static Iterable<String> _repairCandidates(String text) sync* {
    yield text;
    var repaired = text;
    // Label generators that emit “smart” or single quotes use them throughout;
    // only then is swapping them for JSON quotes unambiguous.
    if (!repaired.contains('"')) {
      final swapped = repaired.replaceAll(RegExp('[“”„‟\']'), '"');
      if (swapped != repaired) {
        repaired = swapped;
        yield repaired;
      }
    }
    final controls = _escapeStringControls(repaired);
    if (controls != repaired) {
      repaired = controls;
      yield repaired;
    }
    final structural = _mapOutsideStrings(repaired, (segment) {
      return segment
          // {"a":"b",} → {"a":"b"}
          .replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m[1]!)
          // "lenh":010010000022 is invalid JSON; keep the zeros as a string.
          .replaceAllMapped(
            RegExp(r'([:\[,]\s*)(-?0\d+(?:\.\d+)?)(?=\s*[,}\]])'),
            (m) => '${m[1]}"${m[2]}"',
          );
    });
    if (structural != repaired) yield structural;
  }

  /// Raw CR/LF/TAB inside a JSON string (a multi-line operation name) is
  /// invalid JSON; escape it only inside strings.
  static String _escapeStringControls(String input) {
    final output = StringBuffer();
    var inString = false;
    var escaped = false;
    for (final unit in input.codeUnits) {
      if (inString) {
        if (escaped) {
          output.writeCharCode(unit);
          escaped = false;
          continue;
        }
        if (unit == 0x5C) {
          output.writeCharCode(unit);
          escaped = true;
          continue;
        }
        if (unit == 0x22) {
          output.writeCharCode(unit);
          inString = false;
          continue;
        }
        if (unit < 0x20) {
          output.write(switch (unit) {
            0x08 => r'\b',
            0x09 => r'\t',
            0x0A => r'\n',
            0x0C => r'\f',
            0x0D => r'\r',
            _ => '\\u${unit.toRadixString(16).padLeft(4, '0')}',
          });
          continue;
        }
      } else if (unit == 0x22) {
        inString = true;
      }
      output.writeCharCode(unit);
    }
    return output.toString();
  }

  /// Applies [transform] to the text between JSON string literals only.
  static String _mapOutsideStrings(
    String input,
    String Function(String segment) transform,
  ) {
    final output = StringBuffer();
    final segment = StringBuffer();
    var inString = false;
    var escaped = false;
    for (final unit in input.codeUnits) {
      if (inString) {
        output.writeCharCode(unit);
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5C) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
        }
        continue;
      }
      if (unit == 0x22) {
        output.write(transform(segment.toString()));
        segment.clear();
        output.writeCharCode(unit);
        inString = true;
        continue;
      }
      segment.writeCharCode(unit);
    }
    output.write(transform(segment.toString()));
    return output.toString();
  }

  /// `{"data": {...}}` wrappers: lift one nested level; top-level keys win.
  static Map<String, dynamic> _flatten(Map decoded) {
    final result = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is Map) {
        for (final nested in value.entries) {
          result.putIfAbsent(nested.key.toString(), () => nested.value);
        }
      }
    }
    for (final entry in decoded.entries) {
      if (entry.value is! Map) result[entry.key.toString()] = entry.value;
    }
    return result;
  }

  // Windows-1252 characters in 0x80–0x9F, mapped back to their byte.
  static const Map<int, int> _cp1252 = {
    0x20AC: 0x80,
    0x201A: 0x82,
    0x0192: 0x83,
    0x201E: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x02C6: 0x88,
    0x2030: 0x89,
    0x0160: 0x8A,
    0x2039: 0x8B,
    0x0152: 0x8C,
    0x017D: 0x8E,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201C: 0x93,
    0x201D: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02DC: 0x98,
    0x2122: 0x99,
    0x0161: 0x9A,
    0x203A: 0x9B,
    0x0153: 0x9C,
    0x017E: 0x9E,
    0x0178: 0x9F,
  };

  static String _repairMojibake(String value) {
    // Only text carrying a UTF-8 lead byte read as one character qualifies.
    if (!value.codeUnits.any((unit) => unit >= 0xC2 && unit <= 0xF4)) {
      return value;
    }
    final bytes = <int>[];
    for (final rune in value.runes) {
      if (rune <= 0xFF) {
        bytes.add(rune);
      } else {
        final byte = _cp1252[rune];
        if (byte == null) return value; // Real Unicode text: leave it alone.
        bytes.add(byte);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return value;
    }
  }
}

class ScannedJsonResult {
  /// The payload contained `{`, i.e. it was meant to be JSON.
  final bool attempted;

  /// The decoded object, or null when there was none or it was damaged.
  final Map<String, dynamic>? fields;

  const ScannedJsonResult({required this.attempted, this.fields});

  bool get isDamaged => attempted && fields == null;
}
