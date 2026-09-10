import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'dart:ffi';
import 'package:sqlite3/open.dart' as sqlite3_open;
import 'theme/app_theme.dart';
import 'android_app.dart';
import 'windows_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 必须显式初始化 sqlite3 FFI，否则 DictionaryService.lookup() 静默失败
  // 导致所有非课标词查不到词义（课标词有 VocabService JSON 兜底不受影响）
  if (Platform.isAndroid) {
    sqlite3_open.open.overrideFor(
      sqlite3_open.OperatingSystem.android,
      () => DynamicLibrary.open('libsqlite3.so'),
    );
  }

  if (Platform.isWindows) {
    runApp(const WinEswApp());
  } else {
    runApp(const EswApp());
  }
}

class EswApp extends StatelessWidget {
  const EswApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.primaryBlue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const AndroidEswApp(),
    );
  }
}
