/// Metadata data model and abstract source interface.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A single metadata record returned by a [MetadataSource].
class Metadata {
  String title;
  List<String> authors;
  String isbn;
  String publisher;
  String pubdate;
  String language;
  String description;
  List<String> tags;
  double rating; // 0.0–5.0
  String coverUrl;
  String sourceId;
  String sourceName;

  Metadata({
    this.title = '',
    List<String>? authors,
    this.isbn = '',
    this.publisher = '',
    this.pubdate = '',
    this.language = '',
    this.description = '',
    List<String>? tags,
    this.rating = 0.0,
    this.coverUrl = '',
    this.sourceId = '',
    this.sourceName = '',
  })  : authors = authors ?? [],
        tags = tags ?? [];

  Metadata copyWith({
    String? title,
    List<String>? authors,
    String? isbn,
    String? publisher,
    String? pubdate,
    String? language,
    String? description,
    List<String>? tags,
    double? rating,
    String? coverUrl,
    String? sourceId,
    String? sourceName,
  }) {
    return Metadata(
      title: title ?? this.title,
      authors: authors ?? List.of(this.authors),
      isbn: isbn ?? this.isbn,
      publisher: publisher ?? this.publisher,
      pubdate: pubdate ?? this.pubdate,
      language: language ?? this.language,
      description: description ?? this.description,
      tags: tags ?? List.of(this.tags),
      rating: rating ?? this.rating,
      coverUrl: coverUrl ?? this.coverUrl,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
    );
  }

  Map<String, Object?> toJson() => {
        'title': title,
        'authors': authors,
        'isbn': isbn,
        'publisher': publisher,
        'pubdate': pubdate,
        'language': language,
        'description': description,
        'tags': tags,
        'rating': rating,
        'cover_url': coverUrl,
        'source_id': sourceId,
        'source_name': sourceName,
      };

  factory Metadata.fromJson(Map<String, Object?> json) => Metadata(
        title: (json['title'] as String?) ?? '',
        authors:
            (json['authors'] as List?)?.map((e) => e.toString()).toList() ?? [],
        isbn: (json['isbn'] as String?) ?? '',
        publisher: (json['publisher'] as String?) ?? '',
        pubdate: (json['pubdate'] as String?) ?? '',
        language: (json['language'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
        coverUrl: (json['cover_url'] as String?) ?? '',
        sourceId: (json['source_id'] as String?) ?? '',
        sourceName: (json['source_name'] as String?) ?? '',
      );
}

/// Interface for metadata providers.
abstract class MetadataSource {
  String get id;
  String get name;

  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  });

  /// Fuzzy search by a free-form string; default delegates to [search].
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    return search(title: query, client: client, timeout: timeout);
  }

  Future<Uint8List?> downloadCover(Metadata meta,
      {http.Client? client, Duration timeout = const Duration(seconds: 15)});
}
