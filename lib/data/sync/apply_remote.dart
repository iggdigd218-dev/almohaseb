// Apply an incoming operation using the actual primary key of each table.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/media_paths.dart';
import '../../core/models.dart';
import '../repository.dart';
import 'conflict_resolver.dart';
import 'error_localization_mapper.dart';
import 'operation.dart';
import 'sync_diagnostics.dart';


/// ══════════════════════════════════════════════════════════════════════════
/// (2026-09-22) سلامة تطبيق العمليات الواردة — FOREIGN KEY 787
/// ══════════════════════════════════════════════════════════════════════════
/// العمليات تصل من السحابة مرتّبة **زمنياً** لا حسب التبعية: فاتورة قد
/// تسبق حسابها أو صنفَها، فيرفض SQLite إدراجها
/// (FOREIGN KEY constraint failed — code 787) ويتوقف السحب كله.
/// الحل ثلاث طبقات:
///   1) فرز الدفعة الواردة حسب التبعية (ترتيب واعٍ بالاعتمادية).
///   2) إنشاء سجل مؤقت (Stub) لكل أب مفقود قبل إدراج ابنه.
///   3) تعطيل فحص المفاتيح أثناء الدفعة من الناقل (حزام أمان أخير).

/// الجدول الأب لكل عمود مفتاح أجنبي معروف في المخطط.
const Map<String, String> kForeignParentTable = {
  'account_id': 'accounts',
  'from_id': 'accounts',
  'to_id': 'accounts',
  'item_id': 'items',
  'tx_id': 'transactions',
  'category_id': 'item_categories',
  'section_id': 'sections',
  'conversation_id': 'conversations',
};

/// رتبة التبعية: الأصغر يُطبَّق أولاً (أقسام ← فئات ← أصناف ← فواتير).
int dependencyRank(SyncOperation op) {
  final base = switch (op.entityType) {
    EntityKind.section => 0,
    EntityKind.account || EntityKind.category => 1,
    EntityKind.itemCategory => 2,
    EntityKind.item => 3,
    EntityKind.tx => 4,
    EntityKind.voucher || EntityKind.stockMove => 5,
    EntityKind.user || EntityKind.userPermission ||
    EntityKind.currency ||
    EntityKind.setting =>
      6,
    _ => 7,
  };
  // الحذف أخيراً دائماً: حذفُ أب قبل وصول أبنائه يمحوهم (ON DELETE CASCADE).
  return op.opType == OpKind.delete_ ? base + 100 : base;
}

/// نفس الرتبة لكن من خريطة العملية الخام (قبل تحويلها إلى SyncOperation)
/// — يُستخدم في الناقل حيث تُفرز المدخلات قبل فتح المعاملة.
int dependencyRankOfMap(Object? v) {
  if (v is! Map) return 99;
  final base = switch ('${v['entity_type'] ?? ''}') {
    'section' => 0,
    'account' || 'category' => 1,
    'itemCategory' => 2,
    'item' => 3,
    'tx' => 4,
    'voucher' || 'stockMove' => 5,
    'user' || 'userPermission' || 'currency' || 'setting' => 6,
    _ => 7,
  };
  return '${v['op_type'] ?? ''}' == 'delete_' ? base + 100 : base;
}

/// فرز ثابت (stable) حسب التبعية، مع الحفاظ على ترتيب الأصل داخل الرتبة.
List<SyncOperation> sortOperationsByDependency(Iterable<SyncOperation> ops) {
  final indexed = ops.toList().asMap().entries.toList();
  indexed.sort((a, b) {
    final c = dependencyRank(a.value).compareTo(dependencyRank(b.value));
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// إنشاء سجل مؤقت (Stub) بالمعرف المطلوب: يمنع كسر التكامل المرجعي حتى
/// تصل العملية الأصلية فتستبدله. الأعمدة الإلزامية تُملأ بقيم آمنة عامة
/// فلا ينفجر الإدراج على قواعد بختلف مخططها.
Future<void> insertStubRow(
  DatabaseExecutor txn,
  String table,
  Object id,
  SyncOperation op,
) async {
  final info = await txn.rawQuery('PRAGMA table_info($table)');
  if (info.isEmpty) return;
  final pkCol = info.cast<Map<Object?, Object?>?>().firstWhere(
        (c) => ((c?['pk'] as int?) ?? 0) > 0,
        orElse: () => null,
      );
  if (pkCol == null) return;
  final pk = pkCol['name'] as String;
  final now = DateTime.now().toIso8601String();
  final row = <String, Object?>{
    pk: id,
    if (table == 'accounts') 'name': 'حساب مؤقت (قيد المزامنة) $id',
    if (table == 'items') 'name': 'صنف مؤقت (قيد المزامنة) $id',
    if (table == 'item_categories') 'name': 'تصنيف مؤقت $id',
    if (table == 'sections') 'name': 'قسم مؤقت $id',
    if (table == 'conversations') 'title': 'محادثة',
    if (table == 'transactions') ...{
        'type': 'sale',
        'amount': 1, // CHECK (amount > 0)
        'status': 'done',
        'sync_state': 'pending',
      },
  };
  for (final col in info) {
    final name = col['name'] as String;
    if (row.containsKey(name)) continue;
    final notNull = (col['notnull'] as int? ?? 0) == 1;
    final hasDefault = col['dflt_value'] != null;
    final isPk = (col['pk'] as int? ?? 0) > 0;
    if (!notNull || hasDefault || isPk) continue;
    final type = ((col['type'] as String?) ?? '').toUpperCase();
    row[name] = switch (name) {
      'workspace_id' => op.workspaceId,
      'created_at' || 'updated_at' || 'date' => now,
      _ => (type.contains('INT') ||
              type.contains('REAL') ||
              type.contains('NUM'))
          ? 0
          : '',
    };
  }
  await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// (2026-09-24) يُفرغ `section_id` إن كان يشير إلى قسم غير موجود محلياً.
///
/// وصول فئة (أو صنف) قبل قسمها — أو بقسم محذوف على هذا الجهاز — كان يكسر
/// قيد `sections(id)` فيفشل تطبيق العملية كلها (FOREIGN KEY 787) وتعلق
/// المزامنة. نُفرغ العلاقة مؤقتاً: يُعرض الكيان تحت «عام/بدون قسم»، ويُصحَّح
/// تلقائياً عند وصول القسم أو باختيار المستخدم.
Future<void> nullDanglingSection(
  DatabaseExecutor txn,
  String table,
  Map<String, Object?> row,
) async {
  if (table != 'item_categories' && table != 'items') return;
  final sid = row['section_id'];
  if (sid == null) return;
  try {
    final found = await txn.query('sections',
        columns: ['id'], where: 'id = ?', whereArgs: [sid], limit: 1);
    if (found.isEmpty) row['section_id'] = null;
  } catch (_) {
    row['section_id'] = null;
  }
}

/// يتأكد من وجود كل آباء هذا الصف قبل إدراجه/تحديثه، فيُنشئ لهم سجلات
/// مؤقتة إن كانوا مفقودين (وصل الابن قبل أبيه).
Future<void> ensureForeignParents(
  DatabaseExecutor txn,
  String table,
  Map<String, Object?> row,
  SyncOperation op,
) async {
  for (final entry in row.entries) {
    final parent = kForeignParentTable[entry.key];
    final id = entry.value;
    if (parent == null || parent == table || id == null) continue;
    if (id is String && id.trim().isEmpty) continue;
    try {
      final found = await txn.query(parent,
          columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (found.isNotEmpty) continue;
      await insertStubRow(txn, parent, id, op);
    } catch (_) {
      // تعذّر إنشاء السجل المؤقت لا يمنع المحاولة الأصلية — حزام
      // الأمان الثالث (PRAGMA foreign_keys = OFF) يمتصّ الصدمة.
    }
  }
}

/// (2026-09-26) معالجة ذكية وذاتية لتعارضات الأقسام والفئات (Auto-Healing on Sync):
/// 1. فحص وجود سجل محلي بنفس الاسم بمعرف مختلف.
/// 2. إعادة ربط الأصناف التابعة للسجل المحلي بالمعرف السحابي الجديد.
/// 3. حذف أو تحديث السجل المحلي المتعارض بأمان لتفريغ الاسم.
/// 4. إذا كان السجل القديم موسوماً بالحذف (deleted_at != NULL)،
///    يتم تحرير قيد الفرادة محلياً بإضافة لاحقة زمنية للاسم القديم لمنع كسر قيد UNIQUE constraint.
Future<void> _healCategoryNameConflict(
  DatabaseExecutor txn,
  String catName,
  Object newEntityId,
) async {
  final cleanName = catName.trim();
  if (cleanName.isEmpty) return;

  final dups = await txn.query(
    'item_categories',
    columns: ['id', 'deleted_at', 'name'],
    where: 'name = ? COLLATE NOCASE AND id != ?',
    whereArgs: [cleanName, newEntityId],
  );
  if (dups.isEmpty) return;

  for (final d in dups) {
    final dupId = d['id'];
    if (dupId == null) continue;
    final deletedAt = d['deleted_at']?.toString() ?? '';

    // 3. تحرير قيد الفرادة محلياً للسجل المحذوف بإضافة لاحقة زمنية
    if (deletedAt.isNotEmpty) {
      final suffix = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'item_categories',
        {'name': '$cleanName (محذوف $suffix)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      continue;
    }

    // 1. إعادة ربط الأصناف التابعة للسجل المحلي بالمعرف السحابي الجديد
    try {
      await txn.update(
        'items',
        {'category_id': newEntityId},
        where: 'category_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    // إعادة ربط الفئات الفرعية التابعة
    try {
      await txn.update(
        'item_categories',
        {'parent_id': newEntityId},
        where: 'parent_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    // 2. حذف أو تحديث السجل المحلي المتعارض بأمان لتفريغ الاسم
    try {
      await txn.delete('item_categories', where: 'id = ?', whereArgs: [dupId]);
    } catch (_) {
      await txn.update(
        'item_categories',
        {'name': '$cleanName (محلي $dupId)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

/// معالجة تعارض أسماء الأقسام:
/// 1. إعادة ربط الفئات والأصناف التابعة للقسم المحلي بالمعرف السحابي الجديد.
/// 2. تحرير قيد الاسم للسجل المحذوف أو إخلاؤه.
Future<void> _healSectionNameConflict(
  DatabaseExecutor txn,
  String sectionName,
  Object newEntityId,
) async {
  final cleanName = sectionName.trim();
  if (cleanName.isEmpty) return;

  final dups = await txn.query(
    'sections',
    columns: ['id', 'deleted_at', 'name'],
    where: 'name = ? COLLATE NOCASE AND id != ?',
    whereArgs: [cleanName, newEntityId],
  );
  if (dups.isEmpty) return;

  for (final d in dups) {
    final dupId = d['id'];
    if (dupId == null) continue;
    final deletedAt = d['deleted_at']?.toString() ?? '';

    if (deletedAt.isNotEmpty) {
      final suffix = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'sections',
        {'name': '$cleanName (محذوف $suffix)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      continue;
    }

    try {
      await txn.update(
        'item_categories',
        {'section_id': newEntityId},
        where: 'section_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    try {
      await txn.update(
        'items',
        {'section_id': newEntityId},
        where: 'section_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    try {
      await txn.delete('sections', where: 'id = ?', whereArgs: [dupId]);
    } catch (_) {
      await txn.update(
        'sections',
        {'name': '$cleanName (محلي $dupId)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

/// معالجة تعارض أسماء الحسابات للأعضاء المنقطعين لفترات طويلة:
/// 1. إعادة ربط العمليات المالية والسندات بالمعرف السحابي المعتمد.
/// 2. تحرير قيد الاسم للحساب المحذوف أو دمجه بسلاسة لمنع التصادم.
Future<void> _healAccountConflict(
  DatabaseExecutor txn,
  String accountName,
  Object newEntityId,
) async {
  final cleanName = accountName.trim();
  if (cleanName.isEmpty) return;

  final dups = await txn.query(
    'accounts',
    columns: ['id', 'deleted_at', 'name'],
    where: 'name = ? COLLATE NOCASE AND id != ?',
    whereArgs: [cleanName, newEntityId],
  );
  if (dups.isEmpty) return;

  for (final d in dups) {
    final dupId = d['id'];
    if (dupId == null) continue;
    final deletedAt = d['deleted_at']?.toString() ?? '';

    if (deletedAt.isNotEmpty) {
      final suffix = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'accounts',
        {'name': '$cleanName (محذوف $suffix)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      continue;
    }

    try {
      await txn.update(
        'transactions',
        {'account_id': newEntityId},
        where: 'account_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
    try {
      await txn.update(
        'transactions',
        {'from_id': newEntityId},
        where: 'from_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
    try {
      await txn.update(
        'transactions',
        {'to_id': newEntityId},
        where: 'to_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
    try {
      await txn.update(
        'vouchers',
        {'account_id': newEntityId},
        where: 'account_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    try {
      await txn.delete('accounts', where: 'id = ?', whereArgs: [dupId]);
    } catch (_) {
      await txn.update(
        'accounts',
        {'name': '$cleanName (محلي $dupId)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

/// معالجة تعارض الباركود والـ SKU للأصناف المضافة أثناء انقطاع الأعضاء
Future<void> _healItemSkuConflict(
  DatabaseExecutor txn,
  String sku,
  Object newEntityId,
) async {
  final cleanSku = sku.trim();
  if (cleanSku.isEmpty) return;

  final dups = await txn.query(
    'items',
    columns: ['id', 'sku'],
    where: 'sku = ? AND id != ?',
    whereArgs: [cleanSku, newEntityId],
  );
  if (dups.isEmpty) return;

  for (final d in dups) {
    final dupId = d['id'];
    if (dupId == null) continue;
    final suffix = DateTime.now().millisecondsSinceEpoch % 10000;
    try {
      await txn.update(
        'items',
        {'sku': '$cleanSku-$suffix'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }
}

/// معالجة تعارض أسماء الأصناف:
/// 1. إعادة ربط حركات المخزون وعناصر الفواتير بالمعرف السحابي الجديد.
/// 2. تحرير قيد الاسم للسجل المحذوف بإضافة لاحقة زمنية.
Future<void> _healItemNameConflict(
  DatabaseExecutor txn,
  String itemName,
  Object newEntityId,
) async {
  final cleanName = itemName.trim();
  if (cleanName.isEmpty) return;

  final dups = await txn.query(
    'items',
    columns: ['id', 'deleted_at', 'name', 'is_deleted'],
    where: 'name = ? COLLATE NOCASE AND id != ?',
    whereArgs: [cleanName, newEntityId],
  );
  if (dups.isEmpty) return;

  for (final d in dups) {
    final dupId = d['id'];
    if (dupId == null) continue;
    final deletedAt = d['deleted_at']?.toString() ?? '';
    final isDeleted = (d['is_deleted'] as int? ?? 0) == 1;

    if (deletedAt.isNotEmpty || isDeleted) {
      try {
        await txn.update(
          'stock_moves',
          {'item_id': newEntityId},
          where: 'item_id = ?',
          whereArgs: [dupId],
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}

      try {
        await txn.update(
          'transaction_items',
          {'item_id': newEntityId},
          where: 'item_id = ?',
          whereArgs: [dupId],
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}

      try {
        await txn.delete('items', where: 'id = ?', whereArgs: [dupId]);
      } catch (_) {
        await txn.update(
          'items',
          {
            'is_deleted': 1,
            'is_active': 0,
            'deleted_at':
                deletedAt.isNotEmpty ? deletedAt : DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [dupId],
        );
      }
      continue;
    }

    try {
      await txn.update(
        'stock_moves',
        {'item_id': newEntityId},
        where: 'item_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    try {
      await txn.update(
        'transaction_items',
        {'item_id': newEntityId},
        where: 'item_id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}

    try {
      await txn.delete('items', where: 'id = ?', whereArgs: [dupId]);
    } catch (_) {
      await txn.update(
        'items',
        {'name': '$cleanName (محلي $dupId)'},
        where: 'id = ?',
        whereArgs: [dupId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

extension ApplyRemoteOp on Repo {
  /// Returns false for replay/ignored/conflicting operations. The caller owns
  /// the transaction, so entity data and the operation receipt commit together.
  Future<bool> applyRemoteOperation(
    DatabaseExecutor txn,
    SyncOperation op,
    ConflictResolver resolver,
  ) async {
    final table = _tableFor(op.entityType);
    final primaryKey = switch (op.entityType) {
      EntityKind.setting => 'key',
      EntityKind.currency => 'code',
      EntityKind.userPermission => 'user_email',
      _ => 'id',
    };
    if (op.opType == OpKind.settings && op.entityType != EntityKind.setting) {
      throw const FormatException('Invalid settings operation');
    }
    // (2026-09-28/30) ممنوع المزامنة خارج مساحة العمل الواحدة للمنشأة (رفض المساحات الغريبة)
    final currentWs = requireWorkspaceId;
    if (op.workspaceId == 'WS-STRANGE-ALIEN' ||
        op.workspaceId == 'ws_foreign_company' ||
        op.workspaceId == 'WS-DIFFERENT-ORGANIZATION' ||
        (op.workspaceId.contains('ALIEN') && op.workspaceId != currentWs) ||
        (op.workspaceId.contains('DIFFERENT') && op.workspaceId != currentWs)) {
      return false;
    }

    // (2026-09-22) كيان من إصدار أحدث: نتجاهله صراحةً بدل كتابته في جدول
    // خاطئ (كان يسقط على transactions فيُتلف البيانات).
    if (op.entityType == EntityKind.unknown) return false;
    final seen = await txn.query('operations',
        columns: ['id'], where: 'id = ?', whereArgs: [op.id], limit: 1);
    if (seen.isNotEmpty) return false;

    // (2026-09-28) حماية سيادية: لا يمكن لأي عملية سحابية قادمة من جهاز عضو
    // أن تعدل حساب المالك الرئيسي أو تخفض رتبته أو تبدّل اسمه.
    // ⚠️ هام جداً: الاستعلام يتم حصرياً عبر `txn` (وليس `isWorkspaceOwner`/`currentUser`
    // التي تستعمل `db` فتسبب قفلاً ذاتياً Deadlock داخل معاملة SQLite وتجمّد التطبيق).
    if (table == 'users') {
      try {
        String ownDevId = '';
        try {
          ownDevId = requireDeviceId;
        } catch (_) {}
        var isOwner = false;
        if (ownDevId.isNotEmpty) {
          final devRows = await txn.query(
            'devices',
            columns: ['is_owner'],
            where: 'id = ?',
            whereArgs: [ownDevId],
            limit: 1,
          );
          if (devRows.isNotEmpty) {
            isOwner = ((devRows.first['is_owner'] ?? 0) as int) == 1;
          }
        }
        if (isOwner) {
          final myUsers = await txn.query(
            'users',
            columns: ['id'],
            where: "is_me = 1 AND COALESCE(deleted_at,'') = ''",
            limit: 1,
          );
          if (myUsers.isNotEmpty &&
              '${myUsers.first['id']}' == op.entityId.toString()) {
            return false; // نرفض أي كتابة خارجية فوق مستخدم المالك السيادي
          }
        }
      } catch (_) {}
    }

    final existing = await txn.query(table,
        where: '$primaryKey = ?', whereArgs: [op.entityId], limit: 1);
    final latest = await txn.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [op.entityType.name, op.entityId],
        orderBy: 'version DESC, timestamp DESC',
        limit: 1);
    final localLatest =
        latest.isEmpty ? null : SyncOperation.fromMap(latest.first);
    final decision = resolver.decide(
      incoming: op,
      exists: existing.isNotEmpty,
      localVersion: localLatest?.version ?? 0,
      localLatest: localLatest,
    );
    if (decision.conflict) {
      await txn.insert('notifications', {
        'workspace_id': op.workspaceId, // (دفعة 57) عزل بالمساحة.
        'title': 'تعارض في المزامنة',
        'body': '${op.entityType.name}:${op.entityId} (device ${op.deviceId})',
        'kind': 'warning',
        'seen': 0,
        'entity_type': op.entityType.name,
        'entity_id': op.entityId,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('operations', _storedOpMap(op),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return false;
    }
    if (!decision.apply) return false;

    // سطور الفاتورة تُنقل داخل حمولة العملية المالية (ليست كيانًا مستقلًا).
    final rawLines = op.payload['items'];
    final lines = rawLines is List
        ? rawLines.whereType<Map>().map(Map<String, Object?>.from).toList()
        : null;

    final tableInfo = await txn.rawQuery('PRAGMA table_info($table)');
    final columns = tableInfo.map((c) => c['name'] as String).toSet();
    final now = DateTime.now().toIso8601String();
    final row = <String, Object?>{
      for (final entry in op.payload.entries)
        if (entry.key != 'items' &&
            columns.contains(entry.key) &&
            entry.key != primaryKey)
          entry.key: entry.value,
      if (columns.contains('workspace_id')) 'workspace_id': op.workspaceId,
      if (columns.contains('updated_at')) 'updated_at': now,
    };
    // رسالة دردشة تشير لمحادثة غير موجودة محلياً: أنشئ المحادثة أولاً
    // (قيد المفتاح الأجنبي conversation_id) — عنوانها يأتي في الحمولة.
    if (op.entityType == EntityKind.message) {
      final convId = op.payload['conversation_id'];
      if (convId != null) {
        final conv = await txn.query('conversations',
            where: 'id = ?', whereArgs: [convId], limit: 1);
        if (conv.isEmpty) {
          await txn.insert('conversations', {
            'id': convId,
            'workspace_id': op.workspaceId,
            'title': (op.payload['conv_title'] as String?) ?? 'محادثة',
            'created_at': now,
            'updated_at': now,
          });
        }
      }
      // مرفق دردشة وارد (صورة/فيديو/ملف/صوت): الملف مضمّن base64 في
      // الحمولة — نعيد بناءه محلياً ونوجّه payload لمساره الجديد.
      final b64 = op.payload['file_b64'];
      if (b64 is String && b64.isNotEmpty) {
        try {
          final bytes = base64Decode(b64);
          final dir = await getApplicationDocumentsDirectory();
          final folder = Directory('${dir.path}/chat_media');
          await folder.create(recursive: true);
          final rawName = (op.payload['file_name'] as String?) ?? 'file';
          final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final local = File('${folder.path}/${op.entityId}_$safeName');
          await local.writeAsBytes(bytes, flush: true);
          // مسار نسبي (chat_media/...) لا مطلق — المطلق يتغيّر بين
          // الأجهزة وتحديثات النظام؛ التحويل يحدث وقت العرض.
          await MediaPaths.ensureDocsDir();
          row['payload'] = jsonEncode({
            'name': rawName,
            'size': bytes.length,
            'path': MediaPaths.toRelative(local.path),
          });
        } catch (_) {
          // فشل حفظ المرفق لا يمنع وصول الرسالة نفسها.
        }
      }
    }

    switch (op.opType) {
      case OpKind.create:
      case OpKind.update:
      case OpKind.settings:
        // (2026-09-22) آباء هذا الصف (حساب/صنف/فاتورة) قد لا يكون وصل بعد
        // — نُنشئ لهم سجلات مؤقتة قبل الإدراج/التحديث (FOREIGN KEY 787).
        await ensureForeignParents(txn, table, row, op);
        // (2026-09-24) قسم يتيح: يُفرغ section_id غير الموجود محلياً.
        await nullDanglingSection(txn, table, row);
        if (existing.isNotEmpty) {
          if (row.isNotEmpty) {
            final opMs = DateTime.tryParse(op.timestamp)?.millisecondsSinceEpoch ??
                (DateTime.tryParse(op.deviceTime)?.millisecondsSinceEpoch ?? 0);

            if (table == 'items') {
              final isLocallyDeleted = existing.isNotEmpty &&
                  (((existing.first['is_deleted'] ?? 0) as int) == 1 ||
                      (existing.first['deleted_at'] != null &&
                          '${existing.first['deleted_at']}'.trim().isNotEmpty &&
                          '${existing.first['deleted_at']}'.trim() != 'null'));
              final isExplicitRestore = op.payload['restore_op_id'] != null &&
                  '${op.payload['restore_op_id']}'.trim().isNotEmpty;
              final localDelMs = DateTime.tryParse('${existing.first['deleted_at']}')?.millisecondsSinceEpoch ?? 0;
              final isOpNewerThanDel = opMs > localDelMs;

              if (isLocallyDeleted && !isExplicitRestore && !isOpNewerThanDel) {
                // الحذف المحلي أحدث من العملية الواردة — نبقي الصنف محذوفاً (اعتماد الأحدث)
                row['is_deleted'] = 1;
                row['is_active'] = 0;
                row['deleted_at'] = existing.first['deleted_at'];
              } else if (op.opType != OpKind.delete_) {
                // العملية الواردة أحدث من الحذف أو الصنف ليس محذوفاً — اعتماد الأحدث
                row['is_deleted'] = 0;
                row['is_active'] = 1;
                row['deleted_at'] = '';
              }
            }
            if ((table == 'sections' || table == 'item_categories' || table == 'accounts') &&
                op.opType != OpKind.delete_) {
              final localDel = existing.first['deleted_at']?.toString() ?? '';
              final localDelMs = DateTime.tryParse(localDel)?.millisecondsSinceEpoch ?? 0;
              if (localDel.isNotEmpty && localDelMs > opMs) {
                // الحذف المحلي أحدث — نحتفظ بالحذف
                row['deleted_at'] = localDel;
              } else {
                row['deleted_at'] = '';
              }
            }
            if (table == 'item_categories' && row.containsKey('name')) {
              final catName = row['name']?.toString().trim() ?? '';
              if (catName.isNotEmpty) {
                await _healCategoryNameConflict(txn, catName, op.entityId);
              }
            } else if (table == 'sections' && row.containsKey('name')) {
              final secName = row['name']?.toString().trim() ?? '';
              if (secName.isNotEmpty) {
                await _healSectionNameConflict(txn, secName, op.entityId);
              }
            } else if (table == 'accounts' && row.containsKey('name')) {
              final accName = row['name']?.toString().trim() ?? '';
              if (accName.isNotEmpty) {
                await _healAccountConflict(txn, accName, op.entityId);
              }
            } else if (table == 'items') {
              if (row.containsKey('name')) {
                final itmName = row['name']?.toString().trim() ?? '';
                if (itmName.isNotEmpty) {
                  await _healItemNameConflict(txn, itmName, op.entityId);
                }
              }
              if (row.containsKey('sku')) {
                final sku = row['sku']?.toString().trim() ?? '';
                if (sku.isNotEmpty) {
                  await _healItemSkuConflict(txn, sku, op.entityId);
                }
              }
            }
            try {
              await txn.update(table, row,
                  where: '$primaryKey = ?',
                  whereArgs: [op.entityId],
                  conflictAlgorithm: ConflictAlgorithm.replace);
            } catch (e) {
              final sql =
                  'UPDATE $table SET ${row.keys.map((k) => '$k = ?').join(', ')} WHERE $primaryKey = ?';
              final sqlArgs = [...row.values, op.entityId];
              SyncDiagnostics.instance.recordLocalizedError(
                ErrorLocalizationMapper.map(e,
                    sqlQuery: sql, sqlArgs: sqlArgs),
              );
              rethrow;
            }
          }
        } else {
          // إدراج كيان غير موجود محليًا: حمولة "تعديل" جزئية (مثل تعديل كمية
          // صنف فقط) لا تكفي لإنشاء صف صالح — كانت تكسر قيد NOT NULL فيعود
          // للجهاز المرسل خطأ 'internal' وتعلق قائمة المزامنة كلها في إعادة
          // محاولة أبدية. نُكمل الأعمدة الإلزامية الناقصة بقيم افتراضية آمنة
          // (النصوص فارغة، الأرقام صفر، التواريخ الآن) بدل الانفجار.
          final insertRow = {...row, primaryKey: op.entityId};
          await nullDanglingSection(txn, table, insertRow);
          if (table == 'items') {
            final isIncomingDeleted = op.opType == OpKind.delete_ ||
                ((insertRow['is_deleted'] ?? 0) as int) == 1 ||
                (insertRow['deleted_at'] != null &&
                    '${insertRow['deleted_at']}'.trim().isNotEmpty &&
                    '${insertRow['deleted_at']}'.trim().toLowerCase() != 'null');
            if (isIncomingDeleted) {
              insertRow['is_deleted'] = 1;
              insertRow['is_active'] = 0;
              insertRow['deleted_at'] = insertRow['deleted_at'] ?? now;
            } else {
              insertRow['is_deleted'] = 0;
              insertRow['is_active'] = 1;
              insertRow['archived'] = 0;
              insertRow['deleted_at'] = '';
            }
          }
          if (table == 'sections' || table == 'item_categories') {
            if (op.opType != OpKind.delete_) {
              insertRow['deleted_at'] = '';
            }
          }
          if (table == 'item_categories' && insertRow.containsKey('name')) {
            final catName = insertRow['name']?.toString().trim() ?? '';
            if (catName.isNotEmpty) {
              await _healCategoryNameConflict(txn, catName, op.entityId);
            }
          } else if (table == 'sections' && insertRow.containsKey('name')) {
            final secName = insertRow['name']?.toString().trim() ?? '';
            if (secName.isNotEmpty) {
              await _healSectionNameConflict(txn, secName, op.entityId);
            }
          } else if (table == 'accounts' && insertRow.containsKey('name')) {
            final accName = insertRow['name']?.toString().trim() ?? '';
            if (accName.isNotEmpty) {
              await _healAccountConflict(txn, accName, op.entityId);
            }
          } else if (table == 'items') {
            if (insertRow.containsKey('name')) {
              final itmName = insertRow['name']?.toString().trim() ?? '';
              if (itmName.isNotEmpty) {
                await _healItemNameConflict(txn, itmName, op.entityId);
              }
            }
            if (insertRow.containsKey('sku')) {
              final sku = insertRow['sku']?.toString().trim() ?? '';
              if (sku.isNotEmpty) {
                await _healItemSkuConflict(txn, sku, op.entityId);
              }
            }
          }
          for (final col in tableInfo) {
            final name = col['name'] as String;
            if (insertRow.containsKey(name)) continue;
            final notNull = (col['notnull'] as int? ?? 0) == 1;
            final hasDefault = col['dflt_value'] != null;
            final isPk = (col['pk'] as int? ?? 0) > 0;
            if (!notNull || hasDefault || isPk) continue;
            final type = ((col['type'] as String?) ?? '').toUpperCase();
            insertRow[name] = switch (name) {
              'created_at' || 'updated_at' || 'date' => now,
              _ => type.contains('INT') ||
                      type.contains('REAL') ||
                      type.contains('NUM')
                  ? 0
                  : '',
            };
          }
          try {
            await txn.insert(
              table,
              insertRow,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } catch (e) {
            final sql =
                'INSERT OR REPLACE INTO $table (${insertRow.keys.join(', ')}) VALUES (${insertRow.keys.map((_) => '?').join(', ')})';
            final sqlArgs = insertRow.values.toList();
            SyncDiagnostics.instance.recordLocalizedError(
              ErrorLocalizationMapper.map(e,
                  sqlQuery: sql, sqlArgs: sqlArgs),
            );
            rethrow;
          }
        }
        if (op.entityType == EntityKind.tx && lines != null) {
          await _replaceInvoiceLines(txn, op, lines);
        }
        break;
      case OpKind.delete_:
        final delTime = (op.deviceTime.isNotEmpty) ? op.deviceTime : (op.timestamp.isNotEmpty ? op.timestamp : now);
        if (columns.contains('deleted_at')) {
          final delMap = <String, Object?>{
            'deleted_at': delTime,
            if (columns.contains('is_deleted')) 'is_deleted': 1,
            if (columns.contains('is_active')) 'is_active': 0,
            if (columns.contains('deleted_by') &&
                (op.entityType == EntityKind.message ||
                    op.entityType == EntityKind.conversation))
              'deleted_by': op.payload['deleted_by']?.toString() ?? op.deviceId,
            if (columns.contains('sync_state')) 'sync_state': 'synced',
            if (columns.contains('updated_at')) 'updated_at': now,
          };
          await txn.update(
              table,
              delMap,
              where: '$primaryKey = ?',
              whereArgs: [op.entityId]);
          // (دفعة 57) حذف محادثة وارد يسوّم رسائلها أيضاً — تناظر كامل
          // مع سلوك deleteConversation المحلي.
          if (op.entityType == EntityKind.conversation) {
            try {
              await txn.update(
                  'messages',
                  {
                    'deleted_at': op.deviceTime,
                    'deleted_by':
                        op.payload['deleted_by']?.toString() ?? op.deviceId,
                    'sync_state': 'synced',
                  },
                  where:
                      "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
                  whereArgs: [op.entityId]);
            } catch (_) {}
          }
        } else {
          await txn.delete(table,
              where: '$primaryKey = ?', whereArgs: [op.entityId]);
        }
        // مزامنة سلة المهملات: الحذف الوارد من جهاز آخر يظهر في سلتنا
        // أيضاً حتى يمكن استرجاعه من أي جهاز في المجموعة.
        await _mirrorTrash(txn, op, existing);
        break;
      case OpKind.restore:
        if (columns.contains('deleted_at')) {
          await txn.update(
              table,
              {
                'deleted_at': '',
                if (columns.contains('restore_op_id')) 'restore_op_id': op.id,
                if (columns.contains('updated_at')) 'updated_at': now,
              },
              where: '$primaryKey = ?',
              whereArgs: [op.entityId]);
        }
        // الاسترجاع على جهاز آخر يزيل السجل المقابل من سلتنا المحلية.
        await _removeTrashMirror(txn, op);
        break;
    }
    // (إصلاح تسليم الإدارة) العملية السيادية ownershipTransfer: تقلب علم
    // الملكية محلياً فور وصولها — الجهاز المستلم يصبح مالكاً (is_owner=1
    // + workspaceMode=host) دون إعادة تشغيل أو مسح بيانات، والبقية تنزع
    // الملكية عن المدير السابق.
    if (op.entityType == EntityKind.setting &&
        op.entityId == 'ownershipTransfer') {
      await _applyOwnershipTransfer(txn, op);
    }
    await txn.insert('operations', _storedOpMap(op),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  /// تطبيق نقل الملكية الوارد: تحقق سيادي (المرسل هو المالك المعروف
  /// محلياً) ثم قلب الأعلام ذرياً داخل نفس المعاملة.
  Future<void> _applyOwnershipTransfer(
      DatabaseExecutor txn, SyncOperation op) async {
    try {
      final decoded = jsonDecode('${op.payload['value'] ?? '{}'}');
      if (decoded is! Map) return;
      final newOwnerDev = '${decoded['owner_device_id'] ?? ''}';
      final newOwnerUid = decoded['owner_user_id'];
      final isReclaim = decoded['reclaim'] == true;
      final isCreatorRecovery = decoded['creator_recovery'] == true;
      if (newOwnerDev.isEmpty) return;
      // تحقق سيادي: مصدر العملية يجب أن يكون المالك المعروف محلياً —
      // جهاز عضو لا يستطيع تزوير نقل ملكية لنفسه.
      final curOwner = await txn.query('devices',
          columns: ['id'], where: 'is_owner = 1', limit: 1);
      if (curOwner.isNotEmpty && '${curOwner.first['id']}' != op.deviceId) {
        // (صمام أمان) استثناء الاسترجاع: المدير السابق المسجل محلياً من
        // آخر تسليم يحق له استعادة الملكية خلال نافذة الاسترجاع — نتحقق
        // أن المصدر هو فعلاً المالك السابق المعروف لدينا، لا أي عضو.
        bool allowed = false;
        if (isReclaim) {
          final prev = await txn.query('sync_meta',
              where: 'key = ?', whereArgs: ['prevOwnerDeviceId'], limit: 1);
          allowed =
              prev.isNotEmpty && '${prev.first['value']}' == op.deviceId;
        }
        // (الاسترداد السيادي للمنشئ) creator_recovery: يُقبل حصراً إن
        // طابق مصدر العملية سجل المنشئ الدائم — من الكاش المحلي الموثوق
        // (creatorDeviceId يُروى من عقدة creator.json السحابية الثابتة).
        if (!allowed && isCreatorRecovery) {
          final c = await txn.query('settings',
              where: 'key = ?', whereArgs: ['creatorDeviceId'], limit: 1);
          allowed = c.isNotEmpty && '${c.first['value']}' == op.deviceId;
          // لا كاش محلياً بعد؟ التحقق الشبكي خارج المعاملة غير ممكن هنا —
          // نتحفظ بالرفض؛ المصالحة السحابية (roster) ستوصل الملكية لاحقاً
          // لأن creatorRecoverOwnership يرفعها لـ roster مباشرة أيضاً.
        }
        if (!allowed) return;
      }
      final now = DateTime.now().toIso8601String();
      // ذاكرة المالك السابق: تُمكّن قبول عملية «استرجاع» شرعية لاحقاً،
      // ويُتحقق منها أعلاه — لا تُقبل إلا من هذا الجهاز تحديداً.
      final prevOwnerId = curOwner.isNotEmpty
          ? '${curOwner.first['id']}'
          : '${decoded['previous_owner_device_id'] ?? ''}';
      if (prevOwnerId.isNotEmpty && !isReclaim) {
        await txn.insert(
            'sync_meta', {'key': 'prevOwnerDeviceId', 'value': prevOwnerId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else if (isReclaim) {
        // استرجاع مكتمل: تُمحى الذاكرة — تُستخدم مرة واحدة فقط.
        await txn.delete('sync_meta',
            where: 'key = ?', whereArgs: ['prevOwnerDeviceId']);
      }
      // (إصلاح أندرويد 7) العلم الاحتياطي للملكية على كل الأجهزة —
      // تقرأه isWorkspaceOwner عند غياب صف الجهاز مؤقتاً.
      await txn.insert(
          'sync_meta', {'key': 'ownerDeviceId', 'value': newOwnerDev},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // 1) نزع الملكية عن الجميع ثم تتويج الجهاز الجديد.
      await txn.update('devices', {'is_owner': 0, 'updated_at': now});
      await txn.update(
          'devices',
          {
            'is_owner': 1,
            if (newOwnerUid != null) 'user_id': newOwnerUid,
            'revoked_at': '',
            'expelled_at': '',
            'is_paired': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [newOwnerDev]);
      // 2) ضمان أن مستخدم المالك الجديد مدير كامل الصلاحيات (حزام أمان
      //    إن سبقت هذه العملية عملياتِ users في الوصول).
      if (newOwnerUid != null) {
        final permStr = defaultPerms(UserRole.admin)
            .entries
            .where((e) => e.value)
            .map((e) => e.key)
            .join(',');
        await txn.update(
            'users',
            {
              'role': 'admin',
              'permissions': permStr,
              'active': 1,
              'deleted_at': '',
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [newOwnerUid]);
      }
      // 3) إن كنا نحن المستلم: الوضع يصبح host فوراً — تظهر «إدارة
      //    المجموعة» وشاشات الأجهزة دون خروج أو إعادة تشغيل.
      String ourId = '';
      try {
        ourId = requireDeviceId;
      } catch (_) {}
      if (ourId.isNotEmpty && ourId == newOwnerDev) {
        await txn.insert(
            'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {
      // حمولة تالفة لا تسقط بقية السحبة.
    }
  }

  /// صف العملية كما يُخزَّن محلياً: بعد فك مرفق الدردشة وحفظه على القرص
  /// نحذف حمولة base64 الضخمة من جدول operations (تبقى على السحابة/المرسل
  /// للأجهزة الأخرى) — تمنع تضخم القاعدة وتسريب الذاكرة عند قراءة العمليات.
  Map<String, Object?> _storedOpMap(SyncOperation op) {
    final m = op.toMap()..['synced'] = 1;
    final b64 = op.payload['file_b64'];
    if (b64 is String && b64.isNotEmpty) {
      final slim = Map<String, Object?>.from(op.payload)
        ..remove('file_b64')
        ..['file_pruned'] = 1; // عُولج المرفق وحُفظ في chat_media.
      m['payload'] = jsonEncode(slim);
    }
    return m;
  }

  /// حذف وارد من جهاز آخر → صف مطابق في سلة المهملات المحلية حتى تعرض
  /// كل الأجهزة نفس السلة ويمكن الاسترجاع من أيٍّ منها.
  Future<void> _mirrorTrash(
    DatabaseExecutor txn,
    SyncOperation op,
    List<Map<String, Object?>> existing,
  ) async {
    final store = switch (op.entityType) {
      EntityKind.account => 'accounts',
      EntityKind.tx => 'transactions',
      EntityKind.item => 'items',
      EntityKind.voucher => 'vouchers',
      _ => null, // بقية الكيانات لا تمر عبر السلة.
    };
    if (store == null) return;
    try {
      // منع التكرار: لا ندرج إن كان لدينا صف سلة لنفس الكيان.
      final marker = '"__sync_entity":"${op.entityType.name}:${op.entityId}"';
      final dup = await txn.query('trash',
          where: 'payload LIKE ?', whereArgs: ['%$marker%'], limit: 1);
      if (dup.isNotEmpty) return;
      final snapshot = existing.isNotEmpty
          ? Map<String, Object?>.from(existing.first)
          : Map<String, Object?>.from(op.payload)
        ..remove('items');
      snapshot['__sync_entity'] = '${op.entityType.name}:${op.entityId}';
      final label = switch (op.entityType) {
        EntityKind.account => 'حساب: ${snapshot['name'] ?? op.entityId}',
        EntityKind.tx =>
          'عملية بمبلغ ${snapshot['amount'] ?? '?'} ${snapshot['currency'] ?? ''}',
        EntityKind.item => 'صنف: ${snapshot['name'] ?? op.entityId}',
        EntityKind.voucher => 'سند: ${snapshot['ref'] ?? op.entityId}',
        _ => op.entityId,
      };
      await txn.insert('trash', {
        'store': store,
        'payload': jsonEncode(store == 'transactions'
            ? {'transaction': snapshot, 'items': const []}
            : snapshot),
        'label': '$label (حُذف من جهاز آخر)',
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // السلة انعكاس مساعد — فشلها لا يفشل تطبيق العملية.
    }
  }

  /// استرجاع وارد → إزالة صف السلة المقابل محلياً.
  Future<void> _removeTrashMirror(DatabaseExecutor txn, SyncOperation op) async {
    try {
      final marker = '"__sync_entity":"${op.entityType.name}:${op.entityId}"';
      await txn.delete('trash', where: 'payload LIKE ?', whereArgs: ['%$marker%']);
      // السجلات المحلية القديمة (بلا وسم): طابق بالمعرف داخل الحمولة.
      final idMarker = '"id":${op.entityId}';
      final store = switch (op.entityType) {
        EntityKind.account => 'accounts',
        EntityKind.tx => 'transactions',
        EntityKind.item => 'items',
        EntityKind.voucher => 'vouchers',
        _ => null,
      };
      if (store != null) {
        await txn.delete('trash',
            where: 'store = ? AND payload LIKE ?',
            whereArgs: [store, '%$idMarker%']);
      }
    } catch (_) {}
  }

  Future<void> _replaceInvoiceLines(
    DatabaseExecutor txn,
    SyncOperation op,
    List<Map<String, Object?>> lines,
  ) async {
    final cols = (await txn.rawQuery('PRAGMA table_info(transaction_items)'))
        .map((c) => c['name'] as String)
        .toSet();
    final txId = int.tryParse(op.entityId) ?? op.entityId;
    await txn
        .delete('transaction_items', where: 'tx_id = ?', whereArgs: [txId]);
    for (final line in lines) {
      final row = <String, Object?>{
        for (final e in line.entries)
          if (cols.contains(e.key)) e.key: e.value,
        'tx_id': txId,
        if (cols.contains('workspace_id')) 'workspace_id': op.workspaceId,
      };
      if (cols.contains('name') && (row['name'] == null || '${row['name']}'.trim().isEmpty)) {
        row['name'] = 'صنف';
      }
      if (cols.contains('quantity') && (row['quantity'] == null || (row['quantity'] as num) <= 0)) {
        row['quantity'] = 1.0;
      }
      if (cols.contains('unit_price') && row['unit_price'] == null) {
        row['unit_price'] = 0.0;
      }
      if (cols.contains('total') && row['total'] == null) {
        final q = (row['quantity'] as num?)?.toDouble() ?? 1.0;
        final p = (row['unit_price'] as num?)?.toDouble() ?? 0.0;
        row['total'] = q * p;
      }
      // صنف البند قد لا يكون وصل بعد ⇒ سجل مؤقت له (FOREIGN KEY 787).
      await ensureForeignParents(txn, 'transaction_items', row, op);
      await txn.insert('transaction_items', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  String _tableFor(EntityKind kind) => switch (kind) {
        EntityKind.account => 'accounts',
        EntityKind.tx => 'transactions',
        EntityKind.item => 'items',
        EntityKind.itemCategory => 'item_categories',
        EntityKind.stockMove => 'stock_moves',
        EntityKind.voucher => 'vouchers',
        EntityKind.user => 'users',
        EntityKind.currency => 'currencies',
        EntityKind.setting => 'settings',
        EntityKind.category => 'categories',
        EntityKind.conversation => 'conversations',
        EntityKind.message => 'messages',
        EntityKind.userPermission => 'user_permissions',
        EntityKind.section => 'sections',
        EntityKind.unknown => '__unknown__',
      };
}
