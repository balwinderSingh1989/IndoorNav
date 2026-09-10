import 'dart:convert';
import 'dart:io';

/// Converts legacy edge weights (map units) to physical edge distances.
///
/// Usage:
///   dart run tool/migrate_edge_weights.dart assets/store_data.json [output.json]
///
/// With no output path, the input file is migrated in place.
void main(List<String> arguments) {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln('Usage: dart run tool/migrate_edge_weights.dart <input.json> [output.json]');
    exitCode = 64;
    return;
  }

  final inputPath = arguments[0];
  final outputPath = arguments.length == 2 ? arguments[1] : inputPath;
  final document = jsonDecode(File(inputPath).readAsStringSync());
  if (document is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }

  final metersPerUnit = document['metersPerUnit'];
  if (metersPerUnit is! num || metersPerUnit <= 0) {
    throw const FormatException('Expected a positive numeric metersPerUnit');
  }

  final edges = document['edges'];
  if (edges is! List) {
    throw const FormatException('Expected an edges array');
  }

  for (final edge in edges) {
    if (edge is! Map<String, dynamic>) {
      throw const FormatException('Each edge must be a JSON object');
    }
    final weight = edge.remove('weight');
    if (weight is! num) {
      throw const FormatException('Each edge must contain a numeric weight');
    }
    edge['distanceMeters'] = weight * metersPerUnit;
  }

  const encoder = JsonEncoder.withIndent('  ');
  File(outputPath).writeAsStringSync('${encoder.convert(document)}\n');
  stdout.writeln('Migrated ${edges.length} edges: $inputPath -> $outputPath');
}