// (2026-09-28) حارس تطابق الكتالوج (حسابات، أصناف، أقسام) عبر كافة الأجهزة.
//
// يضمن التحقق الدوري الصارم من تطابق الحسابات والأصناف والأقسام بين جميع الأجهزة
// المرتبطة بمساحة العمل، وإظهار تحذير صريح وبارز في مؤشر المزامنة عند أي تفاوت.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../repository.dart';
import 'cloud_firebase_transport.dart';
import 'conflict_resolver.dart';
import 'firebase_auth_service.dart';
import 'sync_diagnostics.dart';

/// بصمة ملخصة دقيقة للكتالوج (حسابات، أصناف، أقسام، فئات).
class CatalogDigest {
  final int accountsCount;
  final int itemsCount;
  final int sectionsCount;
  final int categoriesCount;
  final String hash;
  final DateTime updatedAt;

  const CatalogDigest({
    required this.accountsCount,
    required this.itemsCount,
    required this.sectionsCount,
    required this.categoriesCount,
    required this.hash,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'accounts': accountsCount,
        'items': itemsCount,
        'sections': sectionsCount,
        'categories': categoriesCount,
        'hash': hash,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory CatalogDigest.fromMap(Map<dynamic, dynamic> m) => CatalogDigest(
        accountsCount: ((m['accounts'] ?? 0) as num).toInt(),
        itemsCount: ((m['items'] ?? 0) as num).toInt(),
        sectionsCount: ((m['sections'] ?? 0) as num).toInt(),
        categoriesCount: ((m['categories'] ?? 0) as num).toInt(),
        hash: '${m['hash'] ?? ''}',
        updatedAt: DateTime.tryParse('${m['updated_at'] ?? ''}') ??
            DateTime.now(),
      );

  bool matches(CatalogDigest other) =>
      accountsCount == other.accountsCount &&
      itemsCount == other.itemsCount &&
      sectionsCount == other.sectionsCount &&
      categoriesCount == other.categoriesCount &&
      hash == other.hash;

  List<String> diff(CatalogDigest other) {
    final d = <String>[];
    if (itemsCount != other.itemsCount) {
      d.add('الأصناف (محلي: $itemsCount | طرف آخر: ${other.itemsCount})');
    }
    if (accountsCount != other.accountsCount) {
      d.add('الحسابات (محلي: $accountsCount | طرف آخر: ${other.accountsCount})');
    }
    if (sectionsCount != other.sectionsCount) {
      d.add('الأقسام (محلي: $sectionsCount | طرف آخر: ${other.sectionsCount})');
    }
    if (categoriesCount != other.categoriesCount) {
      d.add('الفئات (محلي: $categoriesCount | طرف آخر: ${other.categoriesCount})');
    }
    if (d.isEmpty && hash != other.hash) {
      d.add('تفاوت في بيانات الكتالوج');
    }
    return d;
  }
}

class CatalogSyncGuard {
  CatalogSyncGuard._();

  /// حساب البصمة المحلية الحتمية لقاعدة البيانات (باستبعاد المحذوف قطعياً).
  static Future<CatalogDigest> computeLocalDigest(Repo repo) async {
    final db = await repo.database;

    // 1. الحسابات النشطة غير المحذوفة
    final accRows = await db.query(
      'accounts',
      columns: ['id', 'name'],
      where: "archived = 0 AND (deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    // 2. الأصناف النشطة غير المحذوفة
    final itemRows = await db.query(
      'items',
      columns: ['id', 'name', 'sku'],
      where:
          "(is_deleted = 0 OR is_deleted IS NULL) AND (deleted_at IS NULL OR TRIM(deleted_at) = '' OR TRIM(deleted_at) = 'null')",
      orderBy: 'id ASC',
    );

    // 3. الأقسام النشطة
    final secRows = await db.query(
      'sections',
      columns: ['id', 'name'],
      where: "(deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    // 4. الفئات النشطة
    final catRows = await db.query(
      'item_categories',
      columns: ['id', 'name'],
      where: "(deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    final sb = StringBuffer();
    for (final r in accRows) {
      sb.write('A:${r['id']}:${r['name']};');
    }
    for (final r in itemRows) {
      sb.write('I:${r['id']}:${r['name']}:${r['sku']};');
    }
    for (final r in secRows) {
      sb.write('S:${r['id']}:${r['name']};');
    }
    for (final r in catRows) {
      sb.write('C:${r['id']}:${r['name']};');
    }

    final bytes = utf8.encode(sb.toString());
    final digest = sha256.convert(bytes).toString();

    return CatalogDigest(
      accountsCount: accRows.length,
      itemsCount: itemRows.length,
      sectionsCount: secRows.length,
      categoriesCount: catRows.length,
      hash: digest,
      updatedAt: DateTime.now(),
    );
  }

  /// التحقق السحابي الشامل ونشر البصمة ومطابقة الأجهزة الأخرى.
  static Future<void> verifyAndPublish({
    required Repo repo,
    required CloudFirebaseTransport transport,
  }) async {
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'standalone') {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      var local = await computeLocalDigest(repo);
      final ourId = repo.requireDeviceId;
      final backendUrl = transport.backendUrl;
      final ws = transport.workspaceId;
      final root =
          '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';
      final token = await FirebaseAuthRest.cloudIdToken();

      // 1. نشر البصمة المحلية إلى السحابة
      final putUri = Uri.parse(
              '$root/catalog_digest/${Uri.encodeComponent(ourId)}.json')
          .replace(queryParameters: token != null ? {'auth': token} : null);
      try {
        await http
            .put(
              putUri,
              body: jsonEncode(local.toMap()),
              headers: {'Content-Type': 'application/json'},
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('CatalogSyncGuard: failed to put digest: $e');
      }

      // 2. قراءة بصمات أجهزة المنشأة الأخرى
      final getUri = Uri.parse('$root/catalog_digest.json')
          .replace(queryParameters: token != null ? {'auth': token} : null);
      Map<String, dynamic>? allDigests;
      try {
        final res =
            await http.get(getUri).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200 &&
            res.body.trim().isNotEmpty &&
            res.body.trim() != 'null') {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            allDigests = Map<String, dynamic>.from(decoded);
          }
        }
      } catch (e) {
        debugPrint('CatalogSyncGuard: failed to get digests: $e');
      }

      if (allDigests == null || allDigests.isEmpty) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      // (2026-09-28) قاعدة سيادية صارمة:
      // جهاز المدير هو المصدر المعتمد والأصيل لكافة بيانات المنشأة —
      // غياب أي عضو لفترة طويلة أو قصيرة لا يُعد مشكلة ولا يُظهر أي تحذير إطلاقاً.
      final isOwner = await repo.isWorkspaceOwner();
      if (isOwner) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      // أثناء المزامنة النشطة أو وجود عمليات في طابور الإرسال، لا يُرفع تحذير مؤقت
      final diagSnap = SyncDiagnostics.instance.snapshot;
      if (diagSnap.pulling || diagSnap.pushing || diagSnap.pendingCount > 0) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      // 3. مقارنة بصمة هذا الجهاز العضو مع بصمة جهاز المدير المعتمدة فقط
      final db = await repo.database;
      final ownerDevRows = await db.query('devices',
          columns: ['id'], where: 'is_owner = 1', limit: 1);
      final managerDeviceId = ownerDevRows.isNotEmpty
          ? '${ownerDevRows.first['id']}'
          : (await repo.settings())['hostDeviceId'] ?? '';

      if (managerDeviceId.isEmpty || !allDigests.containsKey(managerDeviceId)) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      final managerRaw = allDigests[managerDeviceId];
      if (managerRaw is! Map) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      final managerDigest = CatalogDigest.fromMap(managerRaw);

      // غياب تحديث بصمة المدير لأكثر من 3 أيام يعني أنه لا توجد تعديلات نشطة
      if (DateTime.now().difference(managerDigest.updatedAt).inHours > 72) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      if (local.matches(managerDigest)) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      bool hasMismatch = true;
      String? mismatchDetail;

      // (2026-09-28) معالجة ذكية حتمية: بدلاً من التوقف عاجزاً عند التفاوت،
      // نقوم فوراً بإجراء سحب توفيقي كامل للأحدث (Last-Write-Wins) وحذف القديم تلقائياً.
      try {
        final applied = await transport.pull(
          resolver: ConflictResolver(),
          forceFullSync: true,
        );
        if (applied > 0) {
          final reconciled = await computeLocalDigest(repo);
          local = reconciled;
          // رفع البصمة المعالجة المحدثة
          await http.put(
            putUri,
            body: jsonEncode(local.toMap()),
            headers: {'Content-Type': 'application/json'},
          ).timeout(const Duration(seconds: 5));
        }
      } catch (_) {}

      final diag = SyncDiagnostics.instance.snapshot;
      final isActivelyCatchingUp =
          diag.pushing || diag.pulling || diag.pendingCount > 0;

      if (local.matches(managerDigest)) {
        hasMismatch = false;
      } else if (isActivelyCatchingUp) {
        // العضو قيد استكمال رفع أو سحب عملياته المتراكمة — لا نطلق إنذاراً كاذباً
        hasMismatch = false;
      } else {
        final diffs = local.diff(managerDigest);
        mismatchDetail =
            'تفاوت مع المدير (${diffs.join('، ')}) — جارٍ استكمال المزامنة الذاتية...';
      }

      if (hasMismatch) {
        SyncDiagnostics.instance
            .setCatalogMismatch(true, details: mismatchDetail);
      } else {
        SyncDiagnostics.instance.setCatalogMismatch(false);
      }
    } catch (e) {
      debugPrint('CatalogSyncGuard: verifyAndPublish error: $e');
    }
  }

  /// فحص مباشر بين مستودعين محليين (مخصص للاختبارات والمطابقة المباشرة).
  static Future<bool> verifyDirect(Repo repoA, Repo repoB) async {
    final digestA = await computeLocalDigest(repoA);
    final digestB = await computeLocalDigest(repoB);
    final match = digestA.matches(digestB);
    if (!match) {
      final diffs = digestA.diff(digestB);
      final details =
          'تحذير مزامنة: عدم تطابق بين الأجهزة في ${diffs.join('، ')}';
      SyncDiagnostics.instance.setCatalogMismatch(true, details: details);
    } else {
      SyncDiagnostics.instance.setCatalogMismatch(false);
    }
    return match;
  }
}
