/// Core data models for the Vellum library.
///
/// Ports the Python dataclasses from `vellum/core/models.py`.
library;

/// An author with an optional sort name.
class Author {
  final String name;
  final String sort;

  const Author(this.name, {this.sort = ''});

  Author copyWith({String? name, String? sort}) =>
      Author(name ?? this.name, sort: sort ?? this.sort);

  @override
  bool operator ==(Object other) =>
      other is Author && other.name == name && other.sort == sort;

  @override
  int get hashCode => Object.hash(name, sort);

  @override
  String toString() => 'Author(name: $name, sort: $sort)';
}

/// A book in the library catalogue.
class Book {
  int? id;
  String title;
  List<String> authors;
  String sort;
  String isbn;
  String publisher;
  String pubdate;
  String language;
  String description;
  List<String> tags;
  List<String> formats;
  String coverPath;
  String path;
  double rating;
  String added;
  bool hidden;
  String sourceId;

  Book({
    this.id,
    this.title = '',
    List<String>? authors,
    this.sort = '',
    this.isbn = '',
    this.publisher = '',
    this.pubdate = '',
    this.language = '',
    this.description = '',
    List<String>? tags,
    List<String>? formats,
    this.coverPath = '',
    this.path = '',
    this.rating = 0.0,
    this.added = '',
    this.hidden = false,
    this.sourceId = '',
  })  : authors = authors ?? <String>[],
        tags = tags ?? <String>[],
        formats = formats ?? <String>[];

  /// Returns a copy with the given fields replaced.
  Book copyWith({
    int? Function()? id,
    String? title,
    List<String>? authors,
    String? sort,
    String? isbn,
    String? publisher,
    String? pubdate,
    String? language,
    String? description,
    List<String>? tags,
    List<String>? formats,
    String? coverPath,
    String? path,
    double? rating,
    String? added,
    bool? hidden,
    String? sourceId,
  }) {
    return Book(
      id: id != null ? id() : this.id,
      title: title ?? this.title,
      authors: authors ?? List<String>.of(this.authors),
      sort: sort ?? this.sort,
      isbn: isbn ?? this.isbn,
      publisher: publisher ?? this.publisher,
      pubdate: pubdate ?? this.pubdate,
      language: language ?? this.language,
      description: description ?? this.description,
      tags: tags ?? List<String>.of(this.tags),
      formats: formats ?? List<String>.of(this.formats),
      coverPath: coverPath ?? this.coverPath,
      path: path ?? this.path,
      rating: rating ?? this.rating,
      added: added ?? this.added,
      hidden: hidden ?? this.hidden,
      sourceId: sourceId ?? this.sourceId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Book &&
      other.id == id &&
      other.title == title &&
      _listEquals(other.authors, authors) &&
      other.sort == sort &&
      other.isbn == isbn &&
      other.publisher == publisher &&
      other.pubdate == pubdate &&
      other.language == language &&
      other.description == description &&
      _listEquals(other.tags, tags) &&
      _listEquals(other.formats, formats) &&
      other.coverPath == coverPath &&
      other.path == path &&
      other.rating == rating &&
      other.added == added &&
      other.hidden == hidden &&
      other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        Object.hashAll(authors),
        sort,
        isbn,
        publisher,
        pubdate,
        language,
        description,
        Object.hashAll(tags),
        Object.hashAll(formats),
        coverPath,
        path,
        rating,
        added,
        hidden,
        sourceId,
      );

  @override
  String toString() => 'Book(id: $id, title: $title, authors: $authors, '
      'sort: $sort, isbn: $isbn, publisher: $publisher, pubdate: $pubdate, '
      'language: $language, description: $description, tags: $tags, '
      'formats: $formats, coverPath: $coverPath, path: $path, '
      'rating: $rating, added: $added, hidden: $hidden, sourceId: $sourceId)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
