import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opendocs/main.dart';
import 'package:opendocs/data/document_repository.dart';

void main() {
  testWidgets('empty library renders and theme switches', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const OpenDocsApp());
    await tester.pumpAndSettle();
    expect(find.text('Open file'), findsOneWidget);
    expect(find.text('A quiet place for your documents'), findsOneWidget);
    await tester.tap(find.byTooltip('Toggle theme'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('OpenDocs'))).brightness,
      Brightness.dark,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
  test('library persists and ignores malformed metadata', () async {
    SharedPreferences.setMockInitialValues({
      'library.v1': ['invalid json'],
    });
    final repository = DocumentRepository();
    expect(await repository.load(), isEmpty);
    const document = LocalDocument(
      name: 'Example.pdf',
      path: '/local/example.pdf',
      format: DocumentFormat.pdf,
    );
    await repository.save([document]);
    final loaded = await repository.load();
    expect(loaded.single.name, document.name);
    expect(loaded.single.format, DocumentFormat.pdf);
  });
}
