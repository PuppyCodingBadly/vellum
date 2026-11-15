/// Containment for filesystem paths that come from untrusted documents.
///
/// An EPUB (or any other container we open) hands us paths: archive entry
/// names, OPF hrefs, HTML image sources. None of them may make us read or
/// write outside the directory that belongs to that document. This module is
/// the single place that decides that question: normalize, reject absolutes
/// and `..`, resolve symbolic links, then require the result to stay under
/// the root.
library;

import 'dart:io';

/// Percent-decodes [text], returning it unchanged when a sequence is
/// malformed (`%zz`). Untrusted paths must never abort a parse.
String decodePercentEscapes(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return text; // malformed escape: keep the literal text
  } on FormatException {
    return text;
  }
}

/// Posix segments of [path] after collapsing `//` and `.`, or null when the
/// path is empty, absolute (leading `/` or drive letter) or contains a `..`
/// segment — all of which could name something outside the container.
///
/// Backslashes count as separators so a `..\..` cannot slip through.
List<String>? relativePathSegments(String path) {
  final posix = path.replaceAll('\\', '/');
  if (posix.startsWith('/') || RegExp(r'^[a-zA-Z]:/').hasMatch(posix)) {
    return null;
  }
  final segments = <String>[];
  for (final segment in posix.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    segments.add(segment);
  }
  return segments.isEmpty ? null : segments;
}

/// A directory that paths from untrusted documents may not escape.
///
/// Resolve the root once, then check every path the document supplies against
/// it. Symbolic links are resolved, so a link planted below the root cannot
/// redirect a read or a write outside it.
final class ContainedRoot {
  ContainedRoot._(this.directory);

  /// Canonical absolute form of [directory], or null when it cannot be
  /// resolved (missing, unreadable, or a broken link).
  static ContainedRoot? resolve(String directory) {
    try {
      return ContainedRoot._(Directory(directory).resolveSymbolicLinksSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Canonical absolute form of the root.
  final String directory;

  /// Canonical absolute path named by [path] — absolute, or relative to
  /// [directory] — or null when it leaves the root.
  ///
  /// The target need not exist: the deepest existing ancestor is resolved and
  /// the remaining segments are appended, so a non-existing tail cannot hide a
  /// link out of the root.
  String? path(String path) {
    final candidate = path.startsWith('/') ? _absolute(path) : _relative(path);
    return candidate == null ? null : _contained(candidate);
  }

  /// Like [path], but the target must be an existing regular file.
  String? file(String path) {
    final target = this.path(path);
    if (target == null) return null;
    return FileSystemEntity.typeSync(target) == FileSystemEntityType.file
        ? target
        : null;
  }

  String? _relative(String path) {
    final segments = relativePathSegments(path);
    if (segments == null) return null;
    return '$directory/${segments.join('/')}';
  }

  /// Lexically normalizes an absolute [path]: `.` and empty segments dropped,
  /// `..` popping one segment. Null when it climbs above `/`.
  static String? _absolute(String path) {
    final segments = <String>[];
    for (final segment in path.replaceAll('\\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) return null;
        segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    return '/${segments.join('/')}';
  }

  /// Canonical [candidate] when it stays under [directory].
  String? _contained(String candidate) {
    var probe = candidate;
    final tail = <String>[];
    while (true) {
      if (FileSystemEntity.typeSync(probe, followLinks: false) !=
          FileSystemEntityType.notFound) {
        final String resolved;
        try {
          resolved = File(probe).resolveSymbolicLinksSync();
        } on FileSystemException {
          return null;
        }
        if (resolved != directory && !resolved.startsWith('$directory/')) {
          return null;
        }
        return tail.isEmpty ? resolved : '$resolved/${tail.reversed.join('/')}';
      }
      final slash = probe.lastIndexOf('/');
      if (slash < 0) return null;
      tail.add(probe.substring(slash + 1));
      probe = slash == 0 ? '/' : probe.substring(0, slash);
    }
  }
}
