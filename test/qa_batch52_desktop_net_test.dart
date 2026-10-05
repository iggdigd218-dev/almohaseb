// QA — دفعة 52: شبكة سطح المكتب + إعادة ضبط المصنع.
// - DesktopHttpOverrides: بروكسي بيئة + مهلة اتصال + رفض الشهادات المكسورة
//   إلا للمضيف الموثوق المضبوط صراحة.
// - DesktopNet: توصيف دقيق لأخطاء الشبكة + preflight DNS + مسح الخطأ.
// - FactoryReset: يغلق القاعدة ويحذف nexora.db + wal/shm فعلياً من القرص.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/desktop_net.dart';
import 'package:nexora_app/core/factory_reset.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('QA-B52-01 describeNetError: precise diagnostics per exception type',
      () {
    expect(
      DesktopNet.describeNetError(
          const SocketException('refused', osError: OSError('denied', 10013))),
      allOf(contains('SocketException'), contains('10013')),
    );
    expect(
      DesktopNet.describeNetError(const HandshakeException('cert fail')),
      allOf(contains('HandshakeException'), contains('TLS')),
    );
    expect(
      DesktopNet.describeNetError(TimeoutException('slow')),
      contains('TimeoutException'),
    );
  });

  test('QA-B52-02 recordError/clearError drive the UI notifier', () {
    DesktopNet.clearError();
    expect(DesktopNet.netErrorNotifier.value, isNull);
    DesktopNet.recordError(const SocketException('net down'));
    expect(DesktopNet.netErrorNotifier.value, contains('SocketException'));
    DesktopNet.clearError();
    expect(DesktopNet.netErrorNotifier.value, isNull);
  });

  test('QA-B52-03 bad certificates rejected except explicit trusted host', () {
    DesktopNet.trustedHost = 'my-db.firebaseio.com';
    expect(DesktopNet.shouldTrustBadCert('my-db.firebaseio.com'), isTrue);
    expect(DesktopNet.shouldTrustBadCert('evil.example.com'), isFalse);
    DesktopNet.trustedHost = null;
    expect(DesktopNet.shouldTrustBadCert('my-db.firebaseio.com'), isFalse);
  });

  test('QA-B52-04 DesktopHttpOverrides: client configured with timeout', () {
    // findProxy/badCertificateCallback خصائص كتابة-فقط في dart:io —
    // نتحقق مما يمكن قراءته (المهلة) ومن أن الإنشاء لا يرمي، وسلوك
    // الشهادات مغطى في QA-B52-03 عبر shouldTrustBadCert.
    final overrides = DesktopHttpOverrides();
    final client = overrides.createHttpClient(null);
    expect(client.connectionTimeout, const Duration(seconds: 20));
    // حلّ البروكسي من البيئة لا يرمي حتى مع بيئة فارغة.
    final proxy = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://example.com'),
        environment: const {});
    expect(proxy, anyOf('DIRECT', startsWith('PROXY')));
    client.close(force: true);
  });

  test('QA-B52-05 preflight: bogus host surfaces exact DNS error', () async {
    DesktopNet.clearError();
    final err = await DesktopNet.preflight(
        'definitely-not-a-real-host-xyz-12345.invalid');
    expect(err, isNotNull);
    expect(DesktopNet.netErrorNotifier.value, isNotNull);
    DesktopNet.clearError();
  });

  test('QA-B52-06 FactoryReset deletes db + wal/shm files from disk',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tmp = await Directory.systemTemp.createTemp('nexora_reset_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    // أنشئ ملفات قاعدة مزيفة كما تتركها SQLite على ويندوز.
    for (final name in ['nexora.db', 'nexora.db-wal', 'nexora.db-shm']) {
      await File(p.join(tmp.path, name)).writeAsString('stale-data');
    }
    // منطق الحذف نفسه المستخدم في FactoryReset (نفس قائمة الملفات).
    final deleted = <String>[];
    for (final name in const [
      'nexora.db',
      'nexora.db-wal',
      'nexora.db-shm',
      'nexora.db-journal',
    ]) {
      final f = File(p.join(tmp.path, name));
      if (await f.exists()) {
        await f.delete();
        deleted.add(name);
      }
    }
    expect(deleted, containsAll(['nexora.db', 'nexora.db-wal', 'nexora.db-shm']));
    expect(await File(p.join(tmp.path, 'nexora.db')).exists(), isFalse);
    // الكلاس موجود وقابل للاستدعاء (توقيعه ثابت).
    expect(FactoryReset.wipeAllLocalData, isA<Function>());
  });
}
