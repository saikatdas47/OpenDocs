import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/document_repository.dart';
import 'features/library_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final asset in [
      'assets/OPEN_SOURCE_NOTICES.txt',
    ]) {
      yield LicenseEntryWithLineBreaks([
        'OpenDocs bundled document engines & fonts',
      ], await rootBundle.loadString(asset));
    }
  });
  runApp(const OpenDocsApp());
}

class OpenDocsApp extends StatefulWidget {
  const OpenDocsApp({super.key});
  @override
  State<OpenDocsApp> createState() => _OpenDocsAppState();
}

class _OpenDocsAppState extends State<OpenDocsApp> {
  final repository = DocumentRepository();
  bool dark = false;
  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final saved =
        (await SharedPreferences.getInstance()).getBool('darkTheme') ?? false;
    if (mounted) setState(() => dark = saved);
  }

  void _toggle() {
    setState(() => dark = !dark);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool('darkTheme', dark),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff6559cc),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      brightness: brightness,
      scaffoldBackgroundColor: isDark
          ? const Color(0xff141521)
          : const Color(0xfff5f5fa),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark
            ? const Color(0xff141521)
            : const Color(0xfff5f5fa),
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xff202232) : Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xff202232) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xff202232) : Colors.white,
        elevation: 0,
        height: 72,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark
            ? const Color(0xff141521)
            : const Color(0xfff5f5fa),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenDocs',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    home: LibraryScreen(repository: repository, toggleTheme: _toggle),
  );
}
