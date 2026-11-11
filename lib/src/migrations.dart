import 'dart:collection';

typedef MigrationTransform = Map<String, Object?> Function(
  Map<String, Object?> data,
);

/// Single schema upgrade step transforming [fromVersion] -> [toVersion].
final class SaveMigrationStep {
  final int fromVersion;
  final int toVersion;
  final String description;
  final MigrationTransform transform;

  const SaveMigrationStep({
    required this.fromVersion,
    required this.toVersion,
    required this.transform,
    this.description = '',
  });
}

/// Result produced by [SaveMigrator.migrate].
final class SaveMigrationResult {
  final int fromVersion;
  final int toVersion;
  final List<SaveMigrationStep> appliedSteps;
  final Map<String, Object?> data;

  const SaveMigrationResult({
    required this.fromVersion,
    required this.toVersion,
    required this.appliedSteps,
    required this.data,
  });

  bool get didMigrate => appliedSteps.isNotEmpty;
}

/// Ordered schema migration planner for persistent save/config JSON payloads.
final class SaveMigrator {
  final int targetVersion;
  final String versionField;
  final List<SaveMigrationStep> _steps = [];

  SaveMigrator({
    required this.targetVersion,
    this.versionField = 'schemaVersion',
  });

  void addStep(
    int fromVersion,
    int toVersion,
    MigrationTransform transform, {
    String description = '',
  }) {
    _steps.add(SaveMigrationStep(
      fromVersion: fromVersion,
      toVersion: toVersion,
      transform: transform,
      description: description,
    ));
  }

  SaveMigrationResult migrate(
    Map<String, Object?> rawPayload, {
    int defaultInitialVersion = 0,
  }) {
    final startVer =
        (rawPayload[versionField] as num?)?.toInt() ?? defaultInitialVersion;
    if (startVer == targetVersion) {
      return SaveMigrationResult(
        fromVersion: startVer,
        toVersion: targetVersion,
        appliedSteps: const [],
        data: _deepCloneMap(rawPayload),
      );
    }

    final path = _findChain(startVer, targetVersion);
    if (path == null) {
      throw StateError(
        'No save migration path found from schema v$startVer to v$targetVersion.',
      );
    }

    var working = _deepCloneMap(rawPayload);
    for (final step in path) {
      working = _deepCloneMap(step.transform(working));
      working[versionField] = step.toVersion;
    }

    return SaveMigrationResult(
      fromVersion: startVer,
      toVersion: targetVersion,
      appliedSteps: List.unmodifiable(path),
      data: working,
    );
  }

  List<SaveMigrationStep>? _findChain(int start, int goal) {
    final queue = Queue<List<SaveMigrationStep>>();
    final visited = <int>{start};
    queue.add(const []);

    while (queue.isNotEmpty) {
      final chain = queue.removeFirst();
      final curr = chain.isEmpty ? start : chain.last.toVersion;
      if (curr == goal) return chain;
      for (final step in _steps) {
        if (step.fromVersion == curr && visited.add(step.toVersion)) {
          queue.add([...chain, step]);
        }
      }
    }
    return null;
  }

  static Map<String, Object?> _deepCloneMap(Map<String, Object?> src) {
    final out = <String, Object?>{};
    for (final e in src.entries) {
      out[e.key] = _cloneValue(e.value);
    }
    return out;
  }

  static Object? _cloneValue(Object? v) {
    if (v is Map) {
      return {
        for (final entry in v.entries)
          entry.key.toString(): _cloneValue(entry.value),
      };
    }
    if (v is List) {
      return [for (final item in v) _cloneValue(item)];
    }
    return v;
  }
}
