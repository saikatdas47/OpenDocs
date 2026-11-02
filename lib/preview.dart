import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'data/document_repository.dart';
import 'main.dart' as app;

class PreviewRepository extends DocumentRepository {
  PreviewRepository(this.documents);
  List<LocalDocument> documents;
  @override
  Future<List<LocalDocument>> load() async => documents;
  @override
  Future<void> save(List<LocalDocument> documents) async {
    this.documents = documents;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = <LocalDocument>[];
  for (final entry in {
    'Project brief.pdf': DocumentFormat.pdf,
    'Meeting notes.docx': DocumentFormat.docx,
    'Quarterly review.pptx': DocumentFormat.pptx,
    'Reading list.pdf': DocumentFormat.pdf,
    'Research notes.doc': DocumentFormat.doc,
  }.entries) {
    final response = await http.get(
      Uri.base.resolve('/preview-files/sample.${entry.value.name}'),
    );
    if (response.statusCode == 200) {
      docs.add(
        LocalDocument(
          name: entry.key,
          path: entry.key,
          format: entry.value,
          bytes: response.bodyBytes,
          size: response.bodyBytes.length,
          favorite: docs.length < 2,
          lastOpened: docs.length < 3
              ? DateTime.now().millisecondsSinceEpoch - docs.length * 60000
              : 0,
        ),
      );
    }
  }
  runApp(app.OpenDocsApp(repository: PreviewRepository(docs)));
}
