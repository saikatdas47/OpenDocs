import 'package:flutter/material.dart';

import '../data/document_repository.dart';
import 'slide_pdf_reader_screen.dart';

class OfficeReaderScreen extends StatelessWidget {
  const OfficeReaderScreen({
    super.key,
    required this.document,
    this.thumbnailKey,
  });
  final LocalDocument document;
  final String? thumbnailKey;
  @override
  Widget build(BuildContext context) =>
      SlidePdfReaderScreen(document: document, thumbnailKey: thumbnailKey);
}
