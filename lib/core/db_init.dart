// تهيئة قاعدة البيانات حسب المنصة:
//  - أندرويد/iOS: مصنع sqflite الافتراضي (لا تهيئة).
//  - ويندوز/لينكس/ماك: sqflite_common_ffi (SQLite عبر FFI).
// الملاحظة: الاستيراد آمن على الهاتف لأننا لا نستدعي دوال FFI إلا على سطح المكتب.

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'platform_info.dart';

bool get isDesktop =>
    PlatformInfo.isDesktop;

/// تُستدعى مرة واحدة عند إقلاع التطبيق.
void initDbForPlatform() {
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}

/// مجلد قاعدة البيانات المناسب للمنصة.
Future<String> databaseDirectory() async {
  if (isDesktop) {
    // ويندوز/لينكس: AppData/Roaming؛ ماك: Library.
    final dir = PlatformInfo.isMacOS
        ? await getLibraryDirectory()
        : await getApplicationSupportDirectory();
    return dir.path;
  }
  return getDatabasesPath();
}
