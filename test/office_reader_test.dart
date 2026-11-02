import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendocs/readers/office_text_reader.dart';

Uint8List package(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final data = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('DOCX preserves paragraph and run order including Unicode', () {
    final bytes = package({
      'word/document.xml': '<w:document xmlns:w="urn:w"><w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>বাংলা</w:t></w:r></w:p><w:p><w:r><w:t>Next</w:t></w:r></w:p></w:document>',
    });
    expect(readOfficeText(bytes, false), ['Hello বাংলা\n\nNext']);
  });
  test('PPTX slides use numeric order', () {
    String slide(String text) =>
        '<a:p xmlns:a="urn:a"><a:r><a:t>$text</a:t></a:r></a:p>';
    expect(
      readOfficeText(
        package({
          'ppt/slides/slide10.xml': slide('Ten'),
          'ppt/slides/slide2.xml': slide('Two'),
        }),
        true,
      ),
      ['Two', 'Ten'],
    );
  });
  test('invalid ZIP and unrelated ZIP fail cleanly', () {
    expect(
      () => readOfficeText(Uint8List.fromList([1, 2, 3]), false),
      throwsA(anything),
    );
    expect(
      () => readOfficeText(package({'other.xml': '<x/>'}), false),
      throwsFormatException,
    );
  });
  test('large XML payload rejected before text extraction', () {
    expect(
      () => readOfficeText(
        package({'word/document.xml': 'x' * (17 * 1024 * 1024)}),
        false,
      ),
      throwsFormatException,
    );
  });
}
