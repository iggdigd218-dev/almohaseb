// QA — محرك تشخيص المزامنة (3.71.0).
//
// العقود:
//  - المصنف: Socket/Timeout/5xx ⇒ شبكة · 401/403/permission/cloud-http-4xx
//    ⇒ سحابة · Format/Type/Database/null-check ⇒ كود التطبيق.
//  - لقطة الإرسال: pushStarted/recordPushError/pushFinished — الخطأ يبقى
//    أحمر حتى دورة ناجحة تمسحه.
//  - لقطة الاستقبال: pullFinished(ok/applied) تمسح الخطأ وتسجل المطبق.
//  - refreshQueue: عدّاد صادق للمعلق/الفاشل من sync_queue.
//  - التقرير الفني: يشمل الإصدار ومعرف المنشأة ووسم المصدر.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/sync/sync_diagnostics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final d = SyncDiagnostics.instance;

  setUp(() => d.debugReset());

  group('المصنف', () {
    test('DIAG-01 الشبكة: Socket/Timeout/500/502/503', () {
      expect(SyncDiagnostics.classify(const SocketException('Failed host lookup')),
          SyncFaultSource.network);
      expect(
          SyncDiagnostics.classify(TimeoutException('timed out')), SyncFaultSource.network);
      expect(SyncDiagnostics.classify(StateError('cloud-http-503')),
          SyncFaultSource.network);
      expect(SyncDiagnostics.classify(StateError('cloud-http-500')),
          SyncFaultSource.network);
      expect(SyncDiagnostics.classify(StateError('cloud-http-502')),
          SyncFaultSource.network);
    });

    test('DIAG-02 السحابة: 401/403/Permission Denied/cloud-http-4xx', () {
      expect(SyncDiagnostics.classify(StateError('cloud-auth-failed: 401')),
          SyncFaultSource.cloud);
      expect(SyncDiagnostics.classify(Exception('HTTP 403 from RTDB')),
          SyncFaultSource.cloud);
      expect(SyncDiagnostics.classify(Exception('permission_denied: rules say no')),
          SyncFaultSource.cloud);
      expect(SyncDiagnostics.classify(StateError('cloud-http-404')),
          SyncFaultSource.cloud);
    });

    test('DIAG-03 كود التطبيق: Format/Cast/Null-check/Database', () {
      expect(SyncDiagnostics.classify(const FormatException('bad json')),
          SyncFaultSource.appCode);
      // DatabaseException نوع مجرد — النمط النصي يغطيه في الإنتاج.
      expect(
          SyncDiagnostics.classify(
              Exception('DatabaseException(no such table: users)')),
          SyncFaultSource.appCode);
      // CastError (TypeError فعلياً).
      Object? castErr;
      try {
        const Object o = 'نص';
        (o as int).toString();
      } catch (e) {
        castErr = e;
      }
      expect(SyncDiagnostics.classify(castErr), SyncFaultSource.appCode);
      // Null check operator.
      Object? nullErr;
      try {
        final m = <String, String?>{'a': null};
        m['a']!.length.toString();
      } catch (e) {
        nullErr = e;
      }
      expect(SyncDiagnostics.classify(nullErr), SyncFaultSource.appCode);
      // database_closed نصياً.
      expect(
          SyncDiagnostics.classify(Exception('DatabaseException(database_closed)')),
          SyncFaultSource.appCode);
    });

    test('DIAG-04 استخراج الجدول المتأثر من رسالة القاعدة', () {
      expect(SyncDiagnostics.extractDbDetail('no such table: operations'),
          'الجدول المتأثر: operations');
      expect(SyncDiagnostics.extractDbDetail('error unrelated'), '');
    });
  });

  group('لقطة الإرسال', () {
    test('DIAG-05 دفعة فاشلة: أحمر حتى تمسحه دورة ناجحة', () {
      d.pushStarted();
      expect(d.snapshot.pushing, isTrue);
      d.recordPushError(StateError('cloud-auth-failed: 401'),
          context: 'processQueue → transport.push ← جدول users');
      d.pushFinished();
      var s = d.snapshot;
      expect(s.pushing, isFalse);
      expect(s.uploadFaulted, isTrue);
      expect(s.lastPushFault, SyncFaultSource.cloud);
      expect(s.lastPushCtx, contains('جدول users'));
      // دورة ناجحة تالية تمسح الخطأ.
      d.pushStarted();
      d.pushFinished();
      s = d.snapshot;
      expect(s.uploadFaulted, isFalse);
      expect(s.lastPushOk, isTrue);
      expect(s.lastPushError, isNull);
    });
  });

  group('لقطة الاستقبال', () {
    test('DIAG-06 سحب ناجح يسجل المطبق ويمسح الخطأ السابق', () {
      d.pullFinished(
          ok: false,
          error: const SocketException('no route'),
          context: '_periodicCloudPull → transport.pull');
      expect(d.snapshot.downloadFaulted, isTrue);
      expect(d.snapshot.lastPullFault, SyncFaultSource.network);
      d.pullStarted();
      expect(d.snapshot.pulling, isTrue);
      d.pullFinished(ok: true, applied: 7);
      final s = d.snapshot;
      expect(s.pulling, isFalse);
      expect(s.downloadFaulted, isFalse);
      expect(s.lastPullApplied, 7);
      expect(s.lastPullOk, isTrue);
    });
  });

  group('الطابور والتقارير', () {
    test('DIAG-07 refreshQueue: عدّاد صادق للمعلق/الفاشل', () async {
      final db = await databaseFactory
          .openDatabase(inMemoryDatabasePath);
      await db.execute('CREATE TABLE sync_queue ('
          'id INTEGER PRIMARY KEY, target TEXT, status TEXT)');
      await db.insert('sync_queue', {'target': 'cloud', 'status': 'pending'});
      await db.insert('sync_queue', {'target': 'cloud', 'status': 'syncing'});
      await db.insert('sync_queue', {'target': 'cloud', 'status': 'failed'});
      await db.insert('sync_queue', {'target': 'cloud', 'status': 'synced'});
      await db.insert('sync_queue', {'target': 'lan', 'status': 'pending'});
      await d.refreshQueue(db);
      expect(d.snapshot.pendingCount, 2); // pending + syncing للسحابة فقط.
      expect(d.snapshot.failedCount, 1);
      await db.close();
    });

    test('DIAG-08 التقرير الفني: إصدار ومنشأة ووسم مصدر', () {
      d.pullFinished(
          ok: false,
          error: StateError('cloud-auth-failed: 401'),
          context: 'SSE → transport.pull');
      final r = d.buildTechnicalReport(
        appVersion: '3.71.0+137',
        workspaceId: 'WS-TEST1234',
        deviceId: 'DEVICE-TEST',
        backendUrl: 'https://x.firebasedatabase.app',
      );
      expect(r, contains('3.71.0+137'));
      expect(r, contains('WS-TEST1234'));
      expect(r, contains('DEVICE-TEST'));
      expect(r, contains('[المصدر: السحابة (القواعد/الجلسة)]'));
      expect(r, contains('cloud-auth-failed: 401'));
    });
  });
}
