// (دفعة 58) تطبيق لقطة الانضمام — استُخرجت من LanSyncService المحذوف.
// تُستخدم حصرياً في مسار الانضمام السحابي (CloudJoin.join/completeApprovedJoin):
// تمسح بيانات الجهاز المحلية كاملة وتستبدلها بنسخة المجموعة.
import 'package:sqflite/sqflite.dart';

import '../../core/secret_store.dart';

class SnapshotApply {
  /// يُطبّق لقطة البيانات القادمة من المضيف على الجهاز العضو (يمسح القديم ويستبدله).
  static Future<void> applySnapshot(
    Future<Database> Function() dbProvider,
    String ourDeviceId,
    Map<String, Object?> snap,
  ) async {
    final db = await dbProvider();
    await db.transaction((txn) async {
      final knownDevices =
          await txn.query('devices', columns: ['id', 'auth_secret']);
      final knownSecrets = {
        for (final d in knownDevices) d['id']: d['auth_secret']
      };
      // 1) مسح البيانات المحلية (نُبقي devices/workspaces/sync_meta جزئياً).
      // «حذف كامل»: يشمل أيضاً القوالب والإشعارات وإعدادات العمل القديمة —
      // لا يبقى من بيانات الجهاز القديمة أي أثر بعد الانضمام.
      const clearTables = [
        'sections',
        'templates',
        'notifications',
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in clearTables) {
        await txn.delete(t);
      }
      // نحذف سجلات الأجهزة الأخرى ونُبقي سجلنا وسجل المضيف.
      await txn.delete('devices', where: 'id <> ?', whereArgs: [ourDeviceId]);

      // 2) نسخ الجداول من اللقطة.
      Future<void> insertAll(String table) async {
        final raw = snap[table];
        if (raw is! List) return;
        for (final r in raw) {
          if (r is! Map) continue;
          try {
            final map = <String, Object?>{};
            r.forEach((k, v) {
              if (k is String) map[k] = v as Object?;
            });
            if (table == 'devices') {
              // (دفعة 58) أعمدة LAN أُسقطت من المخطط — لقطات المضيفين
              // الأقدم قد ما تزال تحملها فتُسقط قبل الإدراج.
              map.remove('ip_address');
              map.remove('port');
              if (map['id'] == ourDeviceId ||
                  (map['auth_secret'] as String? ?? '').isEmpty) {
                // سرّنا لا يُكتب أبداً من لقطة واردة؛ وعند غياب السر في
                // اللقطة نحتفظ بما تعلمناه سابقاً عبر الاقتران.
                map['auth_secret'] = knownSecrets[map['id']] ?? '';
              } else {
                // (دفعة 57) سر قرين وارد صريحاً في اللقطة — يُعمّى
                // بمفتاحنا المحلي قبل أن يلمس القرص.
                map['auth_secret'] = await SecretStore.protect(
                    (map['auth_secret'] as String?) ?? '');
              }
              if (map['id'] == ourDeviceId) {
                // سجلنا كما يعرفه المضيف — لسنا مالكين.
                map['is_owner'] = 0;
              } else if ((map['is_owner'] ?? 0) == 1) {
                // تأكد من أن سجل المضيف يظل is_owner=1 (المالك الشرعي).
                map['is_owner'] = 1;
              }
            }
            if (table == 'users') {
              // العضو لا يملك أي مستخدم محلي كـ "أنا"؛ الهوية تأتي من
              // devices.user_id التي يعيّنها المدير لاحقاً.
              map['is_me'] = 0;
            }
            await txn.insert(
              table,
              map,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } catch (_) {}
        }
      }

      await insertAll('workspaces');
      // (3.71.0 — دخول نظيف) العضو يبقى في مساحة المجموعة وحدها: كل صف
      // محلي خارج اللقطة (مساحة شخصية ميتة) يُحذف — كان يظلل مسار
      // المزامنة ويبتلع طلبات المغادرة فلا تصل المدير.
      try {
        final snapWs = snap['workspaces'];
        if (snapWs is List && snapWs.isNotEmpty) {
          final keep = <String>[
            for (final r in snapWs)
              if (r is Map) '${r['id'] ?? ''}'
          ]..removeWhere((e) => e.isEmpty);
          if (keep.isNotEmpty) {
            await txn.delete(
              'workspaces',
              where:
                  'id NOT IN (${List.filled(keep.length, '?').join(',')})',
              whereArgs: keep,
            );
          }
        }
      } catch (_) {}
      await insertAll('users');
      await insertAll('devices');
      await insertAll('accounts');
      await insertAll('transactions');
      await insertAll('transaction_items');
      await insertAll('vouchers');
      await insertAll('currencies');
      await insertAll('categories');
      await insertAll('sections');
      await insertAll('item_categories');
      await insertAll('items');
      await insertAll('stock_moves');
      await insertAll('conversations');
      await insertAll('messages');
      await insertAll('trash');
      await insertAll('activity');

      // 2ب) إعدادات المؤسسة: تُمسح إعدادات العمل القديمة على الجهاز المنضم
      // (اسم المؤسسة/العنوان/التذييل/الشعار القديم...) وتُستبدل بإعدادات
      // المجموعة القادمة في اللقطة — فلا يبقى اسم مؤسسته القديمة على السندات.
      const orgKeys = [
        'businessName',
        'businessNameEn',
        'address',
        'phone',
        'whatsapp',
        'email',
        'managerName',
        'voucherFooter',
        'defaultVoucherNotes',
        'logo',
        'businessActivity',
        'org.icon.b64',
        'user_name',
        'profile_name',
        'profile_phone',
      ];
      for (final k in orgKeys) {
        await txn.delete('settings', where: 'key = ?', whereArgs: [k]);
      }
      final orgSettings = snap['orgSettings'];
      if (orgSettings is Map) {
        for (final e in orgSettings.entries) {
          final k = '${e.key}';
          // الشعار كملف محلي لا يُنقل — أما org.icon.b64 فينقل الشعار المشترك
          if (k == 'logo' || !orgKeys.contains(k)) continue;
          await txn.insert(
              'settings', {'key': k, 'value': '${e.value ?? ''}'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      // 2ج) تحديث تاريخ أول استخدام للمستخدم/الجهاز المنضم لمنع ظهور أي إشعارات قديمة سابقة
      await txn.insert(
        'settings',
        {'key': 'first_use_at', 'value': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // 3) التحقق من دور هذا الجهاز (قاعدة المدير الحتمية):
      // أ) جهاز المنشئ المضيف لمجموعة العمل (ourDeviceId == hostId) هو المدير دوماً بلا تغيير.
      // ب) الجهاز المسجل ببريد إلكتروني هو المدير دوماً (البريد خاص بجهاز المدير فقط).
      final dev = await txn.query('devices',
          where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      final nowIso = DateTime.now().toIso8601String();
      final hostId = '${snap['hostDeviceId'] ?? ''}';

      final emailRow = await txn.query('settings',
          where: "key = 'account.email'", limit: 1);
      final localEmail = emailRow.isNotEmpty
          ? '${emailRow.first['value'] ?? ''}'.trim()
          : '';

      final isHost = ourDeviceId.isNotEmpty && hostId.isNotEmpty && ourDeviceId == hostId;
      final hasLocalEmail = localEmail.isNotEmpty;

      final isHostOrOwner = isHost || hasLocalEmail;

      if (isHostOrOwner) {
        // حماية سيادية: جهاز المدير يبقى مالكاً (is_owner = 1) ووضعه host دوماً
        await txn.update(
          'devices',
          {
            'is_owner': 1,
            'is_paired': 1,
            'revoked_at': '',
            'expelled_at': '',
            'updated_at': nowIso,
          },
          where: 'id = ?',
          whereArgs: [ourDeviceId],
        );
        await txn.insert(
            'sync_meta',
            {
              'key': 'workspaceMode',
              'value': 'host',
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert(
            'sync_meta',
            {
              'key': 'ownerDeviceId',
              'value': ourDeviceId,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        // جهاز العضو الجديد المنضم
        final snapWsList = (snap['workspaces'] as List?)?.whereType<Map>().toList();
        final realWs = snapWsList?.firstWhere(
            (w) => '${w['id'] ?? ''}' != 'default' && '${w['id'] ?? ''}'.isNotEmpty,
            orElse: () => snapWsList.firstOrNull ?? const {});
        final wsId = '${realWs?['id'] ?? 'default'}';
        if (dev.isEmpty) {
          await txn.insert(
            'devices',
            {
              'id': ourDeviceId,
              'workspace_id': wsId,
              'name': 'جهاز عضو',
              'is_owner': 0,
              'is_paired': 1,
              'created_at': nowIso,
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          await txn.update(
            'devices',
            {
              'workspace_id': wsId,
              'is_owner': 0,
              'is_paired': 1,
              'updated_at': nowIso,
            },
            where: 'id = ?',
            whereArgs: [ourDeviceId],
          );
        }
        // ضبط وضع المساحة على "عضو"
        await txn.insert(
            'sync_meta',
            {
              'key': 'workspaceMode',
              'value': 'member',
            },
            conflictAlgorithm: ConflictAlgorithm.replace);

        // منشئ هذه المساحة هو المدير (hostId) وليس جهاز العضو
        if (hostId.isNotEmpty) {
          await txn.insert(
            'settings',
            {'key': 'creatorDeviceId', 'value': hostId},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        // تطهير كامل لأي بريد إلكتروني على جهاز العضو (البريد خاص بالمدير فقط)
        final memberPurgeKeys = [
          'account.email',
          'profile_email',
          'email',
          'account.uid',
          'account.name',
          'account.idToken',
          'account.refreshToken',
        ];
        for (final k in memberPurgeKeys) {
          await txn.delete('settings', where: 'key = ?', whereArgs: [k]);
        }
      }
    });
  }

}
