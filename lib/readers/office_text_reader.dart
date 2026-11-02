import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Deliberately text-only OOXML adapter. No network calls or external conversion.
/// Limits bound decompression; complex formatting and relationships are not rendered.
List<String> readOfficeText(Uint8List bytes, bool slides) {
  if (bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('Office preview limit is 32 MB.');
  }
  final archive = ZipDecoder().decodeBytes(bytes);
  var entries = archive.files
      .where(
        (file) => slides
            ? RegExp(r'^ppt/slides/slide[0-9]+\.xml$').hasMatch(file.name)
            : file.name == 'word/document.xml',
      )
      .toList();
  entries.sort((a, b) => _number(a.name).compareTo(_number(b.name)));
  if (entries.isEmpty) {
    throw const FormatException('No readable Office content found.');
  }
  if (entries.length > 500 ||
      entries.fold<int>(0, (sum, f) => sum + f.size) > 16 * 1024 * 1024) {
    throw const FormatException('Document is too large for the basic preview.');
  }
  return entries.map((file) {
    final xml = XmlDocument.parse(utf8.decode(file.content as List<int>));
    return xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'p')
        .map(
          (p) => p.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((t) => t.innerText)
              .join(),
        )
        .join('\n\n');
  }).toList();
}

int _number(String name) =>
    int.tryParse(RegExp(r'[0-9]+').firstMatch(name)?.group(0) ?? '') ?? 0;
