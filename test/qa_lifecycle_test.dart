import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/recorder.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

class _LifecycleDb implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #update ||
        invocation.memberName == #rawUpdate) {
      return Future<int>.value(0);
    }
    if (invocation.memberName == #query || invocation.memberName == #rawQuery) {
      return Future<List<Map<String, Object?>>>.value([]);
    }
    return super.noSuchMethod(invocation);
  }
}

class _LifecycleRepo extends Repo {
  @override
  Future<Map<String, String>> settings() async => {};
  @override
  Future<bool> isWorkspaceOwner() async => true;
  @override
  Future<List<String>> autoExpireStaleDevices() async => [];
}

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  test(
      'QA-LIFE-01 stopping engine cancels all timers and detaches recorder callback',
      () async {
    final timers = <Timer>[];
    final engine = SyncEngine(
        repo: _LifecycleRepo(), dbProvider: () async => _LifecycleDb());
    final zone = ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createTimer(zone, duration, callback);
        timers.add(timer);
        return timer;
      },
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createPeriodicTimer(zone, duration, callback);
        timers.add(timer);
        return timer;
      },
    );
    try {
      await runZoned(() async {
        await engine.start();
        engine.notifyNewOperation();
        engine.stop();
        await Future<void>.delayed(Duration.zero);
      }, zoneSpecification: zone);
      expect(engine.hasStarted, isFalse);
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(SyncRecorder.onOperationRecorded, isNull);
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
      SyncRecorder.onOperationRecorded = null;
    }
  });
}
