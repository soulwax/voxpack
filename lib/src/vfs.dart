import 'dart:convert';
import 'dart:typed_data';

import 'pak.dart';

/// POSIX-style virtual path normalizer (`.` / `..` resolution, slash canonicalization).
final class VfsPath {
  static String normalize(String raw) {
    final replaced = raw.replaceAll('\\', '/');
    final segments = <String>[];
    for (final part in replaced.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else {
        segments.add(part);
      }
    }
    return segments.join('/');
  }

  static RegExp globToRegExp(String pattern) {
    final norm = normalize(pattern);
    final buf = StringBuffer('^');
    for (int i = 0; i < norm.length; i++) {
      final ch = norm[i];
      if (ch == '*') {
        if (i + 1 < norm.length && norm[i + 1] == '*') {
          buf.write('.*');
          i++;
          if (i + 1 < norm.length && norm[i + 1] == '/') {
            buf.write('(?:.*/)?');
            // Avoid double matching the preceding .* + slash
            return _compileCleanGlob(norm);
          }
        } else {
          buf.write('[^/]*');
        }
      } else if (ch == '?') {
        buf.write('[^/]');
      } else {
        buf.write(RegExp.escape(ch));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }

  static RegExp _compileCleanGlob(String norm) {
    final buf = StringBuffer('^');
    var i = 0;
    while (i < norm.length) {
      if (i + 2 < norm.length && norm.substring(i, i + 3) == '**/') {
        buf.write('(?:.*/)?');
        i += 3;
      } else if (i + 1 < norm.length && norm.substring(i, i + 2) == '**') {
        buf.write('.*');
        i += 2;
      } else if (norm[i] == '*') {
        buf.write('[^/]*');
        i++;
      } else if (norm[i] == '?') {
        buf.write('[^/]');
        i++;
      } else {
        buf.write(RegExp.escape(norm[i]));
        i++;
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }
}

/// Single read source mounted into a [VirtualFileSystem].
abstract class VfsMount {
  final String id;
  int priority;

  VfsMount({required this.id, this.priority = 0});

  bool exists(String normalizedPath);
  Uint8List? readBytes(String normalizedPath);
  Iterable<String> listPaths();

  String? readText(String normalizedPath) {
    final bytes = readBytes(normalizedPath);
    return bytes == null ? null : utf8.decode(bytes);
  }
}

/// Mutable in-memory VFS layer (ideal for runtime overrides or test fixtures).
final class MemoryMount extends VfsMount {
  final Map<String, Uint8List> _files = {};

  MemoryMount({super.id = 'memory', super.priority = 10});

  void writeBytes(String virtualPath, Uint8List bytes) {
    _files[VfsPath.normalize(virtualPath)] = Uint8List.fromList(bytes);
  }

  void writeText(String virtualPath, String content) =>
      writeBytes(virtualPath, Uint8List.fromList(utf8.encode(content)));

  bool remove(String virtualPath) =>
      _files.remove(VfsPath.normalize(virtualPath)) != null;

  void clear() => _files.clear();

  @override
  bool exists(String normalizedPath) => _files.containsKey(normalizedPath);

  @override
  Uint8List? readBytes(String normalizedPath) => _files[normalizedPath];

  @override
  Iterable<String> listPaths() => _files.keys;
}

/// Read-only VFS layer backed by a parsed [PakArchive].
final class PakMount extends VfsMount {
  final PakArchive archive;
  final bool verifyChecksums;

  PakMount({
    required super.id,
    required this.archive,
    super.priority = 0,
    this.verifyChecksums = true,
  });

  @override
  bool exists(String normalizedPath) => archive.contains(normalizedPath);

  @override
  Uint8List? readBytes(String normalizedPath) =>
      archive.readBytes(normalizedPath, verifyChecksum: verifyChecksums);

  @override
  Iterable<String> listPaths() => archive.entries.map((e) => e.path);
}

/// Layered virtual filesystem resolving asset paths from highest-priority mounts first.
final class VirtualFileSystem {
  final List<VfsMount> _mounts = [];

  List<VfsMount> get mounts => List.unmodifiable(_mounts);

  void mount(VfsMount layer) {
    _mounts.removeWhere((m) => m.id == layer.id);
    _mounts.add(layer);
    _mounts.sort((a, b) => b.priority.compareTo(a.priority));
  }

  bool unmount(String id) {
    final before = _mounts.length;
    _mounts.removeWhere((m) => m.id == id);
    return _mounts.length != before;
  }

  bool exists(String path) {
    final norm = VfsPath.normalize(path);
    for (final m in _mounts) {
      if (m.exists(norm)) return true;
    }
    return false;
  }

  String? resolveMountId(String path) {
    final norm = VfsPath.normalize(path);
    for (final m in _mounts) {
      if (m.exists(norm)) return m.id;
    }
    return null;
  }

  Uint8List? readBytes(String path) {
    final norm = VfsPath.normalize(path);
    for (final m in _mounts) {
      if (m.exists(norm)) return m.readBytes(norm);
    }
    return null;
  }

  String? readText(String path) {
    final norm = VfsPath.normalize(path);
    for (final m in _mounts) {
      if (m.exists(norm)) return m.readText(norm);
    }
    return null;
  }

  /// Returns sorted deduplicated paths across all mounts matching [globPattern].
  List<String> list({String? globPattern}) {
    final regex = globPattern != null ? VfsPath.globToRegExp(globPattern) : null;
    final found = <String>{};
    for (final m in _mounts) {
      for (final p in m.listPaths()) {
        if (regex == null || regex.hasMatch(p)) {
          found.add(p);
        }
      }
    }
    final list = found.toList()..sort();
    return list;
  }
}
