import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opendocs/data/document_repository.dart';
import 'package:opendocs/features/library_screen.dart';

class MemoryRepository extends DocumentRepository {
  MemoryRepository(this.items);
  List<LocalDocument> items;
  @override
  Future<List<LocalDocument>> load() async => items;
  @override
  Future<void> save(List<LocalDocument> documents) async {
    items = documents;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'storageIntroSeen': false});
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      StorageBridge.channel,
      null,
    );
  });
  test(
    'scan merges by source path and preserves favorites and reading position',
    () {
      const imported = LocalDocument(
        name: 'Saved.pdf',
        path: '/private/saved.pdf',
        format: DocumentFormat.pdf,
      );
      const old = LocalDocument(
        name: 'Notes.docx',
        path: '/shared/notes.docx',
        format: DocumentFormat.docx,
        owned: false,
        favorite: true,
        lastOpened: 123,
        position: 8,
      );
      const stale = LocalDocument(
        name: 'Gone.pdf',
        path: '/shared/gone.pdf',
        format: DocumentFormat.pdf,
        owned: false,
      );
      const scanned = LocalDocument(
        name: 'Notes.docx',
        path: '/shared/notes.docx',
        format: DocumentFormat.docx,
        owned: false,
        size: 100,
      );
      final merged = DocumentRepository.mergeScan(
        [imported, old, stale],
        [scanned],
      );
      expect(merged.length, 2);
      expect(merged.last.favorite, isTrue);
      expect(merged.last.position, 8);
      expect(merged.last.lastOpened, 123);
      expect(
        DocumentRepository.mergeScan(
          [old, stale],
          [scanned],
          complete: false,
        ).length,
        2,
      );
    },
  );
  testWidgets('mobile library search, format filter and favorite workflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = MemoryRepository([
      const LocalDocument(
        name: 'Report.pdf',
        path: '/r.pdf',
        format: DocumentFormat.pdf,
      ),
      const LocalDocument(
        name: 'Plan.docx',
        path: '/p.docx',
        format: DocumentFormat.docx,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(repository: repository, toggleTheme: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('Plan.docx'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Word'));
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsNothing);
    expect(find.text('Plan.docx'), findsOneWidget);
    await tester.tap(find.byTooltip('Add to favorites'));
    await tester.pumpAndSettle();
    expect(repository.items.last.favorite, isTrue);
    await tester.tap(find.text('Favorites').last);
    await tester.pumpAndSettle();
    expect(find.text('Plan.docx'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching documents'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
  testWidgets(
    'Android asks before storage access and scans only after permission',
    (tester) async {
      final calls = <String>[];
      var allowed = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        StorageBridge.channel,
        (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'accessStatus':
              return {'allFiles': allowed, 'folders': 0};
            case 'takeIncoming':
              return [];
            case 'requestAccess':
              allowed = true;
              return true;
            case 'scan':
              return {
                'documents': [
                  {
                    'name': 'Slides.pptx',
                    'path': '/shared/Slides.pptx',
                    'owned': false,
                    'size': 500,
                  },
                ],
                'skipped': 0,
                'truncated': false,
                'cancelled': false,
              };
          }
          return null;
        },
      );
      final repository = MemoryRepository([]);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(repository: repository, toggleTheme: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bring your documents together'), findsOneWidget);
      expect(calls, isNot(contains('requestAccess')));
      expect(calls, isNot(contains('scan')));
      await tester.tap(find.text('Allow storage access & scan'));
      await tester.pumpAndSettle();
      expect(calls.indexOf('requestAccess'), lessThan(calls.indexOf('scan')));
      expect(repository.items.single.name, 'Slides.pptx');
      expect(find.text('Slides.pptx'), findsOneWidget);
    },
  );
  testWidgets('denied storage permission keeps manual opening available', (
    tester,
  ) async {
    var scanCalled = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      StorageBridge.channel,
      (call) async {
        if (call.method == 'accessStatus') {
          return {'allFiles': false, 'folders': 0};
        }
        if (call.method == 'takeIncoming') return [];
        if (call.method == 'requestAccess') return false;
        if (call.method == 'scan') scanCalled = true;
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          repository: MemoryRepository([]),
          toggleTheme: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow storage access & scan'));
    await tester.pumpAndSettle();
    expect(scanCalled, isFalse);
    expect(find.text('Open file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
