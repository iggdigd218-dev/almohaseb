import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db_init.dart';

/// معرف Workspace الافتراضي (ثابت محلي لتجنب circular imports).
const defaultWorkspaceIdConst = 'default';

/// قاعدة البيانات المحلية — تقابل مخازن IndexedDB في نسخة الويب،
/// لكن بجداول SQL حقيقية مع فهارس ومفاتيح أجنبية.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static Database? _db;
  static Future<Database>? _opening;
  static const int _version = 27;

  static int get schemaVersion => _version;

  /// حقن قاعدة في الذاكرة للاختبارات.
  static void overrideForTest(Database db) {
    _db = db;
    _opening = null;
  }

  Future<Database> get database {
    if (_db != null) return Future.value(_db!);
    return _opening ??= _openDb().then((db) {
      _db = db;
      return db;
    }, onError: (Object e, StackTrace st) {
      _opening = null;
      Error.throwWithStackTrace(e, st);
    });
  }

  Future<Database> _openDb() async {
    final dir = await databaseDirectory();
    var schemaJustMigrated = false;
    return openDatabase(
      p.join(dir, 'nexora.db'),
      version: _version,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        schemaJustMigrated = true;
        await createSchema(db);
      },
      onUpgrade: (db, from, to) async {
        schemaJustMigrated = true;
        await _migrate(db, from, to);
      },
      onOpen: (db) async {
        // إذا لم تُنفَّذ الهجرة للتو في onCreate/onUpgrade، نتحقق مما إذا كان
        // المخطط الكامل قد فُحص مسبقاً لهذا الإصدار لتفادي تشغيل ~180 استعلام
        // DDL في كل إقلاع مما يبطئ فتح الحسابات محلياً.
        if (!schemaJustMigrated) {
          var alreadyEnsured = false;
          try {
            final rows = await db.query(
              'sync_meta',
              columns: ['value'],
              where: 'key = ?',
              whereArgs: ['schema_ensured_v'],
              limit: 1,
            );
            alreadyEnsured =
                rows.isNotEmpty && '${rows.first['value']}' == '$_version';
          } catch (_) {
            alreadyEnsured = false;
          }
          if (!alreadyEnsured) {
            await ensureFullSchema(db);
          }
        }
        await repairOwnerAdminStatus(db);
      },
    );
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null && db.isOpen) await db.close();
  }

  /// إنشاء كل الجداول — مستقل ليُستخدم في الاختبارات أيضًا.
  static Future<void> createSchema(Database db) async {
    // ---------- البنية الجديدة للمزامنة ----------
    await execSchemaScript(db, createSyncSchemaSql);

    // ---------- الحسابات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id    TEXT NOT NULL DEFAULT 'default',
        name            TEXT NOT NULL,
        kind            TEXT NOT NULL DEFAULT 'customer',
        opening_balance REAL NOT NULL DEFAULT 0,
        currency        TEXT NOT NULL DEFAULT 'YER',
        phone           TEXT DEFAULT '',
        whatsapp        TEXT DEFAULT '',
        address         TEXT DEFAULT '',
        notes           TEXT DEFAULT '',
        category        TEXT DEFAULT '',
        credit_limit    REAL,
        tags            TEXT DEFAULT '',
        archived        INTEGER NOT NULL DEFAULT 0,
        image           TEXT DEFAULT '',
        notify_channel  TEXT NOT NULL DEFAULT 'whatsapp',
        deleted_at      TEXT DEFAULT '',
        deleted_by      INTEGER,
        restore_op_id   TEXT DEFAULT '',
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
      )''');
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_acc_kind ON accounts(kind)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_acc_arch ON accounts(archived)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_acc_del  ON accounts(deleted_at)');

    // ---------- العمليات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        account_id   INTEGER,
        account_kind TEXT DEFAULT 'customer',
        type         TEXT NOT NULL,
        amount       REAL NOT NULL CHECK (amount > 0),
        currency     TEXT NOT NULL DEFAULT 'YER',
        sign         TEXT DEFAULT '',
        from_id      INTEGER,
        to_id        INTEGER,
        rate         REAL NOT NULL DEFAULT 1,
        description  TEXT DEFAULT '',
        reference    TEXT DEFAULT '',
        notes        TEXT DEFAULT '',
        category     TEXT DEFAULT '',
        attachment   TEXT DEFAULT '',
        attachment_hash TEXT DEFAULT '',
        image        TEXT DEFAULT '',
        status       TEXT NOT NULL DEFAULT 'done',
        sync_state   TEXT NOT NULL DEFAULT 'synced',
        created_by_user_id INTEGER,
        cashier_name TEXT DEFAULT '',
        date         TEXT NOT NULL,
        deleted_at   TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE,
        FOREIGN KEY (from_id)    REFERENCES accounts (id) ON DELETE CASCADE,
        FOREIGN KEY (to_id)      REFERENCES accounts (id) ON DELETE CASCADE
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tx_acc ON transactions(account_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tx_date ON transactions(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tx_from ON transactions(from_id)');
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_tx_to ON transactions(to_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tx_del ON transactions(deleted_at)');
    // قواعد قديمة أنشأت الجدول قبل v20 بدون عمود التجزئة — أضفه (idempotent).
    await _addColumn(db, 'transactions', 'attachment_hash', "TEXT DEFAULT ''");

    // ---------- السندات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vouchers (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        number      TEXT NOT NULL,
        kind        TEXT NOT NULL,
        account_id  INTEGER,
        tx_id       INTEGER,
        amount      REAL NOT NULL DEFAULT 0,
        currency    TEXT NOT NULL DEFAULT 'YER',
        statement   TEXT DEFAULT '',
        notes       TEXT DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'draft',
        created_by_user_id INTEGER,
        cashier_name TEXT DEFAULT '',
        date        TEXT NOT NULL,
        deleted_at  TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE SET NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_v_acc ON vouchers(account_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_v_del ON vouchers(deleted_at)');

    // ---------- العملات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS currencies (
        code    TEXT NOT NULL,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name    TEXT NOT NULL,
        symbol  TEXT NOT NULL,
        decimal INTEGER NOT NULL DEFAULT 0,
        rate    REAL NOT NULL DEFAULT 1,
        deleted_at TEXT DEFAULT '',
        PRIMARY KEY (code, workspace_id)
      )''');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_curr_pk_v21 '
        'ON currencies(code, workspace_id)');

    // ---------- التصنيفات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name       TEXT NOT NULL,
        scope      TEXT NOT NULL DEFAULT 'account',
        created_at TEXT NOT NULL
      )''');

    // ---------- المستخدمون والصلاحيات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name        TEXT NOT NULL,
        role        TEXT NOT NULL DEFAULT 'viewer',
        pin         TEXT DEFAULT '',
        password    TEXT DEFAULT '',
        permissions TEXT DEFAULT '',
        is_me       INTEGER NOT NULL DEFAULT 0,
        active      INTEGER NOT NULL DEFAULT 1,
        can_apply_discount INTEGER NOT NULL DEFAULT 1,
        deleted_at  TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
      )''');

    // (اجتثاث الورديات والمستخدمين المحليين) كل جهاز يعمل بحساب مستخدم واحد
    await db.execute('DROP TABLE IF EXISTS local_staff');

    // ---------- الدردشة ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        title      TEXT NOT NULL,
        deleted_at TEXT DEFAULT '',
        deleted_by TEXT DEFAULT '',
        sync_state TEXT DEFAULT 'synced',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        workspace_id    TEXT NOT NULL DEFAULT 'default',
        sender          TEXT NOT NULL DEFAULT '',
        body            TEXT DEFAULT '',
        kind            TEXT NOT NULL DEFAULT 'text',
        payload         TEXT DEFAULT '',
        deleted_at      TEXT DEFAULT '',
        deleted_by      TEXT DEFAULT '',
        sync_state      TEXT DEFAULT 'synced',
        created_at      TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id)');

    // ---------- سجل النشاط ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS activity (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        text       TEXT NOT NULL,
        ref_type   TEXT DEFAULT '',
        ref_id     TEXT DEFAULT '',
        user_name  TEXT DEFAULT '',
        created_at TEXT NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_act_date ON activity(created_at)');

    // ---------- سلة المحذوفات القديمة (يبقى للتوافق مع الإصدارات السابقة) ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS trash (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        store      TEXT NOT NULL,
        payload    TEXT NOT NULL,
        label      TEXT DEFAULT '',
        created_at TEXT NOT NULL
      )''');

    // ---------- التنبيهات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        title       TEXT NOT NULL,
        body        TEXT DEFAULT '',
        kind        TEXT DEFAULT 'info',
        seen        INTEGER NOT NULL DEFAULT 0,
        entity_type TEXT DEFAULT '',
        entity_id   TEXT DEFAULT '',
        created_at  TEXT NOT NULL
      )''');
    // قواعد قديمة أنشأت الجدول بدون عمودَي الربط — أضفهما (idempotent).
    await _addColumn(db, 'notifications', 'entity_type', "TEXT DEFAULT ''");
    await _addColumn(db, 'notifications', 'entity_id', "TEXT DEFAULT ''");
    await _addColumn(
        db, 'notifications', 'workspace_id', "TEXT NOT NULL DEFAULT 'default'");

    // ---------- قوالب الرسائل ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS templates (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT NOT NULL,
        body       TEXT NOT NULL,
        created_at TEXT NOT NULL
      )''');

    // ---------- الإعدادات ----------
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');

    // ====== (3.70) الصلاحيات المحلية RBAC + بريد المستخدم ======
    // تُنشأ هنا أيضاً (وليس فقط في _ensureCoreSyncTables) لأن مسار
    // createSchema المباشر هو ما تستخدمه الاختبارات والقواعد الجديدة.
    await _tryCreateTable(db, 'user_permissions', '''
        CREATE TABLE IF NOT EXISTS user_permissions (
          user_email TEXT PRIMARY KEY,
          store_id TEXT,
          role TEXT,
          user_id INTEGER,
          can_discount INTEGER DEFAULT 0,
          can_delete_tx INTEGER DEFAULT 0,
          can_view_reports INTEGER DEFAULT 0,
          can_manage_items INTEGER DEFAULT 0,
          is_active INTEGER DEFAULT 1,
          updated_at INTEGER
        )''');
    await _tryCreateIndex(
      db,
      'idx_user_perms_store',
      'CREATE INDEX IF NOT EXISTS idx_user_perms_store ON user_permissions(store_id)',
    );
    await _addColumn(db, 'users', 'email', "TEXT DEFAULT ''");

    await _seed(db);
  }

  /// شبكة أمان تُستدعى عند كل فتح قاعدة بيانات: تضمن وجود جداول المزامنة
  /// الأساسية + Workspace افتراضي + كل جداول الأعمال + بذرة دنيا.
  /// كل خطواتها idempotent (IF NOT EXISTS / ConflictAlgorithm.ignore)
  /// فآمنة للتكرار في كل إقلاع، وأي خطأ غير متوقع يُبتلع حتى لا يُسقط
  /// التطبيق عند الفتح (لا يُفترض أن يحدث، لكنه خط دفاع أخير).
  static Future<void> ensureFullSchema(Database db) async {
    try {
      await _ensureCoreSyncTables(db);
    } catch (_) {}
    try {
      // ينشئ جداول الأعمال الناقصة (idempotent) ويتجاوز تعارض الجداول.
      await createSchema(db);
    } catch (_) {
      // حتى لو فشل السكربت متعدد الجُمل، لا تنهار الباقي.
    }
    try {
      // (دفعة 57) قواعد قديمة فُتحت بلا onUpgrade (نفس الرقم) لكن ناقصة
      // أعمدة v21 — الهجرة idempotent فتصلح أي نقص عند كل فتح.
      await migrateToV21(db);
    } catch (_) {}
    try {
      // (دفعة 58) اجتثاث بقايا LAN عند كل فتح — idempotent بالكامل.
      await migrateToV22(db);
    } catch (_) {}
    try {
      // أعمدة الورديات وربط العمليات بالكاشير وصلاحية الخصم
      await _addColumn(db, 'transactions', 'created_by_user_id', 'INTEGER');
      await _addColumn(db, 'transactions', 'cashier_name', "TEXT DEFAULT ''");
      await _addColumn(db, 'vouchers', 'created_by_user_id', 'INTEGER');
      await _addColumn(db, 'vouchers', 'cashier_name', "TEXT DEFAULT ''");
      await _addColumn(db, 'users', 'can_apply_discount', 'INTEGER NOT NULL DEFAULT 1');
      await _addColumn(db, 'user_permissions', 'user_id', 'INTEGER');
      await _tryCreateIndex(
        db,
        'idx_user_perms_ws_user',
        'CREATE INDEX IF NOT EXISTS idx_user_perms_ws_user ON user_permissions(store_id, user_id)',
      );
      await db.execute('DROP TABLE IF EXISTS local_staff');
    } catch (_) {}
  }

  /// ══ (2026-09-28) ترميم سيادي لرتبة واسم مدير النظام للمالك ══
  /// المشكلة: عند تخصيص صلاحيات لجهاز عضو كان يتم خفض رتبة مستخدم المدير إلى 'viewer'
  /// وتغيير اسمه بنفس اسم جهاز العضو!
  /// الحل: فحص فوري عند كل فتح — إذا كان هذا الجهاز مالك المنشأة:
  /// 1) فك أي ربط خاطئ لأجهزة الأعضاء بحساب المدير وفصلها في حسابات مستقلة.
  /// 2) ضمان وجود رتبة admin مع كافة الصلاحيات و is_me = 1 للمالك.
  /// 3) ترميم اسم المالك الحقيقي فوراً ومنع تلوّثه باسم أي جهاز عضو.
  static Future<void> repairOwnerAdminStatus(Database db) async {
    try {
      final metaMode = await db.query('sync_meta',
          where: "key = 'workspaceMode'", limit: 1);
      final isMember =
          metaMode.isNotEmpty && metaMode.first['value'] == 'member';
      if (isMember) return; // أجهزة الأعضاء تتبع ما يُعيّنه المالك

      const adminPerms =
          'manage_users,edit_tx,delete_tx,view_reports,manage_backup,approve_vouchers,manage_catalog';

      // 1. تحديد مستخدم المالك (is_me = 1 أو أول مستخدم)
      final myUser = await db.query('users',
          where: "is_me = 1 AND COALESCE(deleted_at,'') = ''", limit: 1);
      final myUserId = myUser.isNotEmpty
          ? (myUser.first['id'] as int)
          : 1;

      // 2. فك أي ارتباط خاطئ بين أجهزة الأعضاء وحساب المالك
      final memberDevs = await db.query('devices', where: "is_owner = 0");
      for (final mDev in memberDevs) {
        final devUid = mDev['user_id'] as int?;
        if (devUid != null && devUid == myUserId) {
          final newMemberUid = DateTime.now().microsecondsSinceEpoch % 1000000000;
          final mName = (mDev['name'] as String?)?.trim().isNotEmpty == true
              ? (mDev['name'] as String).trim()
              : 'عضو';
          await db.insert('users', {
            'id': newMemberUid,
            'name': mName,
            'role': 'cashier',
            'permissions': 'add_tx,view_reports',
            'is_me': 0,
            'active': 1,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await db.update('devices', {'user_id': newMemberUid},
              where: 'id = ?', whereArgs: [mDev['id']]);
        }
      }

      // 3. التحقق إن كان هناك أي مدير نظام حالياً وضمان رتبة المالك
      final admins = await db.query('users',
          where: "role = 'admin' AND COALESCE(deleted_at,'') = ''", limit: 1);

      if (admins.isEmpty) {
        if (myUser.isNotEmpty) {
          await db.update('users', {
            'role': 'admin',
            'permissions': adminPerms,
            'active': 1,
          }, where: 'id = ?', whereArgs: [myUserId]);
        } else {
          final firstUser = await db.query('users',
              where: "COALESCE(deleted_at,'') = ''",
              orderBy: 'id ASC',
              limit: 1);
          if (firstUser.isNotEmpty) {
            await db.update('users', {
              'role': 'admin',
              'is_me': 1,
              'permissions': adminPerms,
              'active': 1,
            }, where: 'id = ?', whereArgs: [firstUser.first['id']]);
          }
        }
      }

      // 4. ترميم اسم المالك إذا كان قد تلوّث باسم العضو
      final memberNames = memberDevs
          .map((d) => (d['name'] as String?)?.trim() ?? '')
          .where((n) => n.isNotEmpty)
          .toSet();

      final ownerDev = await db.query('devices', where: "is_owner = 1", limit: 1);
      final ownerDevName = ownerDev.isNotEmpty ? (ownerDev.first['name'] as String?)?.trim() : null;
      final settingDevName = await db.query('settings', where: "key = 'sync.deviceName'", limit: 1);
      final savedDevName = settingDevName.isNotEmpty ? (settingDevName.first['value'] as String?)?.trim() : null;
      final businessNameRow = await db.query('settings', where: "key = 'businessName'", limit: 1);
      final bizName = businessNameRow.isNotEmpty ? (businessNameRow.first['value'] as String?)?.trim() : null;

      final preferredOwnerName = (savedDevName != null && savedDevName.isNotEmpty && savedDevName != 'جهاز' && !memberNames.contains(savedDevName))
          ? savedDevName
          : ((ownerDevName != null && ownerDevName.isNotEmpty && ownerDevName != 'جهاز' && !memberNames.contains(ownerDevName))
              ? ownerDevName
              : ((bizName != null && bizName.isNotEmpty && !memberNames.contains(bizName)) ? bizName : 'المدير'));

      if (myUser.isNotEmpty) {
        final curName = (myUser.first['name'] as String?)?.trim() ?? '';
        if (memberNames.contains(curName) || curName.isEmpty) {
          await db.update('users', {
            'name': preferredOwnerName,
            'updated_at': DateTime.now().toIso8601String(),
          }, where: 'id = ?', whereArgs: [myUserId]);
        }
      }
    } catch (_) {}
  }

  /// جداول المزامنة الجديدة (v5).
  static const createSyncSchemaSql = '''
      CREATE TABLE IF NOT EXISTS workspaces (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL DEFAULT '',
        owner_google_id TEXT DEFAULT '',
        owner_email     TEXT DEFAULT '',
        owner_name      TEXT DEFAULT '',
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS devices (
        id             TEXT PRIMARY KEY,
        workspace_id   TEXT NOT NULL,
        name           TEXT NOT NULL DEFAULT '',
        platform       TEXT DEFAULT '',
        app_version    TEXT DEFAULT '',
        last_seen_at   TEXT DEFAULT '',
        last_sync_at   TEXT DEFAULT '',
        pair_token     TEXT DEFAULT '',
        pair_token_exp TEXT DEFAULT '',
        auth_secret    TEXT DEFAULT '',
        revoked_at     TEXT DEFAULT '',
        expelled_at    TEXT DEFAULT '',
        user_id        INTEGER,
        paired_by      INTEGER,
        is_paired      INTEGER NOT NULL DEFAULT 1,
        is_owner       INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL,
        updated_at     TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
      );

      CREATE TABLE IF NOT EXISTS operations (
        id           TEXT PRIMARY KEY,
        device_id    TEXT NOT NULL,
        workspace_id TEXT NOT NULL,
        user_id      INTEGER,
        entity_type  TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        op_type      TEXT NOT NULL,
        version      INTEGER NOT NULL DEFAULT 1,
        parent_op_id TEXT DEFAULT '',
        payload      TEXT NOT NULL,
        device_time  TEXT NOT NULL,
        server_time  TEXT DEFAULT '',
        timestamp    TEXT NOT NULL,
        synced       INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_ops_entity ON operations(entity_type, entity_id);
      CREATE INDEX IF NOT EXISTS idx_ops_time   ON operations(timestamp);
      CREATE INDEX IF NOT EXISTS idx_ops_sync   ON operations(synced, timestamp);

      CREATE TABLE IF NOT EXISTS sync_queue (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        operation_id TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'pending',
        target       TEXT NOT NULL DEFAULT 'cloud',
        attempts     INTEGER NOT NULL DEFAULT 0,
        last_error   TEXT DEFAULT '',
        next_try_at  TEXT DEFAULT '',
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        UNIQUE(operation_id, target),
        FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_queue_status ON sync_queue(status, next_try_at);

      CREATE TABLE IF NOT EXISTS sync_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS google_auth (
        id           INTEGER PRIMARY KEY CHECK (id = 1),
        google_id    TEXT DEFAULT '',
        email        TEXT DEFAULT '',
        display_name TEXT DEFAULT '',
        photo_url    TEXT DEFAULT '',
        id_token     TEXT DEFAULT '',
        signed_in_at TEXT DEFAULT '',
        updated_at   TEXT DEFAULT ''
      );
  ''';


  /// ترقية المخطط مع الحفاظ على كل البيانات القائمة.
  /// ينشئ جداول المزامنة المفقودة بأمان (للدفاع ضد قواعد قديمة ناقصة).
  static Future<void> _ensureCoreSyncTables(Database db) async {
    await _tryCreateTable(
      db,
      'sync_meta',
      'CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await _tryCreateTable(db, 'workspaces', '''
        CREATE TABLE IF NOT EXISTS workspaces (
          id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
          owner_google_id TEXT DEFAULT '', owner_email TEXT DEFAULT '',
          owner_name TEXT DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        )''');
    await _tryCreateTable(db, 'devices', '''
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
          name TEXT NOT NULL DEFAULT '', platform TEXT DEFAULT '',
          app_version TEXT DEFAULT '', last_seen_at TEXT DEFAULT '',
          last_sync_at TEXT DEFAULT '', pair_token TEXT DEFAULT '',
          pair_token_exp TEXT DEFAULT '', auth_secret TEXT DEFAULT '',
          revoked_at TEXT DEFAULT '', expelled_at TEXT DEFAULT '',
          user_id INTEGER, paired_by INTEGER,
          is_paired INTEGER NOT NULL DEFAULT 1, is_owner INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        )''');
    await _tryCreateTable(db, 'operations', '''
        CREATE TABLE IF NOT EXISTS operations (
          id TEXT PRIMARY KEY, device_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
          user_id INTEGER, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
          op_type TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
          parent_op_id TEXT DEFAULT '', payload TEXT NOT NULL,
          device_time TEXT NOT NULL, server_time TEXT DEFAULT '',
          timestamp TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0
        )''');
    await _tryCreateTable(db, 'sync_queue', '''
        CREATE TABLE IF NOT EXISTS sync_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', target TEXT NOT NULL DEFAULT 'cloud',
          attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT DEFAULT '',
          next_try_at TEXT DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          UNIQUE(operation_id, target)
        )''');
    await _tryCreateTable(db, 'google_auth', '''
        CREATE TABLE IF NOT EXISTS google_auth (
          id INTEGER PRIMARY KEY CHECK (id = 1), google_id TEXT DEFAULT '',
          email TEXT DEFAULT '', display_name TEXT DEFAULT '', photo_url TEXT DEFAULT '',
          id_token TEXT DEFAULT '', signed_in_at TEXT DEFAULT '', updated_at TEXT DEFAULT ''
        )''');
    // ====== (3.70) الصلاحيات المحلية RBAC — المرجع user_email لا الجهاز ======
    await _tryCreateTable(db, 'user_permissions', '''
        CREATE TABLE IF NOT EXISTS user_permissions (
          user_email TEXT PRIMARY KEY,
          store_id TEXT,
          role TEXT,
          user_id INTEGER,
          can_discount INTEGER DEFAULT 0,
          can_delete_tx INTEGER DEFAULT 0,
          can_view_reports INTEGER DEFAULT 0,
          can_manage_items INTEGER DEFAULT 0,
          is_active INTEGER DEFAULT 1,
          updated_at INTEGER
        )''');
    await _tryCreateIndex(
      db,
      'idx_user_perms_store',
      'CREATE INDEX IF NOT EXISTS idx_user_perms_store ON user_permissions(store_id)',
    );
    // بريد المستخدم لصفوف users — مفتاح الربط مع user_permissions.
    await _addColumn(db, 'users', 'email', "TEXT DEFAULT ''");
    // تأكد من وجود Workspace افتراضي.
    final wsExists = await db.rawQuery(
      'SELECT id FROM workspaces WHERE id = ?',
      [defaultWorkspaceIdConst],
    );
    if (wsExists.isEmpty) {
      final now = DateTime.now().toIso8601String();
      await db.insert('workspaces', {
        'id': defaultWorkspaceIdConst,
        'name': 'متجري',
        'owner_google_id': '',
        'owner_email': '',
        'owner_name': '',
        'created_at': now,
        'updated_at': now,
      });
    }
    // تأكد من وجود صف schemaVersion.
    final sv = await db.rawQuery('SELECT value FROM sync_meta WHERE key = ?', [
      'schemaVersion',
    ]);
    if (sv.isEmpty) {
      await db.insert('sync_meta', {
        'key': 'schemaVersion',
        'value': '$_version',
      });
    }
    // إصلاح هجرة قديمة: تحويل أي مستخدم role='manager' إلى 'admin' (كان يسبب viewer بدون صلاحيات)
    try {
      await db.execute("UPDATE users SET role='admin' WHERE role='manager'");
      await db.execute(
        "UPDATE users SET permissions='add_tx,edit_tx,delete_tx,view_reports,export,manage_backup,manage_users,approve_vouchers' WHERE role='admin' AND (permissions IS NULL OR TRIM(permissions)='')",
      );
    } catch (_) {}
  }

  static Future<void> _tryCreateTable(
    Database db,
    String name,
    String sql,
  ) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [name],
    );
    if (rows.isEmpty) await db.execute(sql);
  }

  /// ينفّذ نصًا قد يحتوي عدة جُمل CREATE (سكربت مخطط) بشكل متين:
  /// - يقسّمه على الفواصل المنقوطة وينفّذ كل جملة على حدة.
  /// - إذا فشلت جملة لأن الجدول/الفهرس موجود مسبقًا (خطأ حصل في بناءات
  ///   ويندوز القديمة التي استخدمت CREATE TABLE بدون IF NOT EXISTS) يتجاوزها
  ///   بدل أن تنهار الهجرة بالكامل وتُظهر "table workspaces already exists".
  static Future<void> execSchemaScript(Database db, String script) async {
    // أولاً جرّب التنفيذ المباشر (الأسرع، يدعم المحرك الجُمل المتعددة).
    try {
      await db.execute(script);
      return;
    } catch (e) {
      if (!_isAlreadyExistsError('$e')) rethrow;
    }
    // مسار التحوّط: نفّذ كل جملة مفردة وتجاوز "already exists".
    final statements = _splitStatements(script);
    for (final stmt in statements) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      try {
        await db.execute(trimmed);
      } catch (e) {
        if (_isAlreadyExistsError('$e')) continue;
        // أخطاء أخرى (مثل نقص عمود في جدول قديم) لا تُبتلع هنا في الإنشاء.
        rethrow;
      }
    }
  }

  static bool _isAlreadyExistsError(String msg) {
    final m = msg.toLowerCase();
    return m.contains('already exists') ||
        m.contains('duplicate column') ||
        m.contains('error code 1)');
  }

  /// يقسّم سكربت SQL إلى جُمل على الفواصل المنقوطة خارج الأقواس/النصوص.
  static List<String> _splitStatements(String script) {
    final out = <String>[];
    final buf = StringBuffer();
    bool inStr = false;
    String? strCh;
    for (var i = 0; i < script.length; i++) {
      final ch = script[i];
      if (inStr) {
        buf.write(ch);
        if (ch == strCh) {
          // تجاوز الفاصلة المزدوجة (هروب).
          if (i + 1 < script.length && script[i + 1] == strCh) {
            buf.write(script[i + 1]);
            i++;
          } else {
            inStr = false;
          }
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        inStr = true;
        strCh = ch;
        buf.write(ch);
        continue;
      }
      if (ch == ';') {
        final s = buf.toString().trim();
        if (s.isNotEmpty) out.add(s);
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    final s = buf.toString().trim();
    if (s.isNotEmpty) out.add(s);
    return out;
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    // هذا يُصلح الحالات التي كانت فيها قواعد البيانات القديمة مفقودة لبعض الجداول
    // (مثل sync_meta) بسبب نسخ سابقة من التطبيق.
    await _ensureCoreSyncTables(db);

    if (from < 2) {
      await _addColumn(db, 'transactions', 'image', "TEXT DEFAULT ''");
      await _addColumn(db, 'users', 'password', "TEXT DEFAULT ''");
    }
    // ====== Migration v4 -> v5: بنية Local-First Sync ======
    if (from < 5) {
      await _migrate4to5(db);
    }
    // ====== v6: إضافة auth_secret للأجهزة (للتحقق من هوية الجهاز المرسل في LAN) ======
    if (from < 6) {
      await _addColumn(db, 'devices', 'auth_secret', "TEXT DEFAULT ''");
    }
    // ====== v7: إضافة أعمدة لمنع الأجهزة الملغاة + معرفات مرجعية ======
    if (from < 7) {
      await _addColumn(db, 'devices', 'revoked_at', "TEXT DEFAULT ''");
    }
    // ====== v8: فهارس إضافية لتحسين أداء sync_queue + operations ======
    if (from < 8) {
      await _tryCreateIndex(
        db,
        'idx_queue_target_status',
        'CREATE INDEX IF NOT EXISTS idx_queue_target_status ON sync_queue(target, status, next_try_at)',
      );
      await _tryCreateIndex(
        db,
        'idx_ops_ws_time',
        'CREATE INDEX IF NOT EXISTS idx_ops_ws_time ON operations(workspace_id, timestamp)',
      );
    }
    // ====== v9: حقل last_synced_op في sync_meta للمزامنة التزايدية ======
    if (from < 9) {
      // لا شيء — sync_meta موجود بالفعل، ونستخدمه كـ key-value عادي.
      await _ensureCoreSyncTables(db);
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '9',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v10: حماية دفاعية للتأكد من وجود sync_meta وجداول المزامنة (إصلاح عاجل). ======
    if (from < 10) {
      await _ensureCoreSyncTables(db);
      // تأكد من وجود أعمدة v6/v7 في devices إن كانت ناقصة.
      await _addColumn(db, 'devices', 'auth_secret', "TEXT DEFAULT ''");
      await _addColumn(db, 'devices', 'revoked_at', "TEXT DEFAULT ''");
      // تأكد من وجود فهارس v8.
      await _tryCreateIndex(
        db,
        'idx_queue_target_status',
        'CREATE INDEX IF NOT EXISTS idx_queue_target_status ON sync_queue(target, status, next_try_at)',
      );
      await _tryCreateIndex(
        db,
        'idx_ops_ws_time',
        'CREATE INDEX IF NOT EXISTS idx_ops_ws_time ON operations(workspace_id, timestamp)',
      );
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '10',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v11: عمود قناة الإشعار لكل حساب (واتساب/رسالة نصية/بدون). ======
    if (from < 11) {
      await _addColumn(
        db,
        'accounts',
        'notify_channel',
        "TEXT NOT NULL DEFAULT 'whatsapp'",
      );
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '11',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v12: إدارة الأجهزة: ربط كل جهاز بمستخدم + من قام بمنح الصلاحية. ======
    if (from < 12) {
      await _addColumn(db, 'devices', 'user_id', 'INTEGER');
      await _addColumn(db, 'devices', 'paired_by', 'INTEGER');
      // الجهاز الحالي (هذا الهاتف) يُربط بالمستخدم 'أنا' (المدير افتراضياً).
      try {
        final me = await db.query(
          'users',
          where: "is_me = 1 AND COALESCE(deleted_at,'') = ''",
          limit: 1,
        );
        if (me.isNotEmpty) {
          final myUid = me.first['id'];
          await db.update(
              'devices',
              {
                'user_id': myUid,
                'paired_by': myUid,
                'is_paired': 1,
              },
              where: "auth_secret <> '' AND revoked_at = ''");
        }
      } catch (_) {}
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '12',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v13: وضع المساحة (مستقل/مرتبط) + is_owner للجهاز المالك ======
    if (from < 13) {
      await _addColumn(db, 'devices', 'is_owner', "INTEGER NOT NULL DEFAULT 0");
      // في الوضع المستقل (قبل أي اقتران)، الجهاز المحلي هو المالك.
      final localDev = await db.query(
        'devices',
        where: "auth_secret <> '' AND COALESCE(revoked_at,'') = ''",
        orderBy: 'created_at ASC',
        limit: 1,
      );
      if (localDev.isNotEmpty) {
        final ownerDeviceId = localDev.first['id'];
        final anyPeer = await db.query(
          'devices',
          where: "id <> ? AND is_paired = 1 AND COALESCE(revoked_at,'') = ''",
          whereArgs: [ownerDeviceId],
          limit: 1,
        );
        // إذا لا يوجد جهاز آخر فهذا الجهاز هو المالك (وضع مستقل).
        if (anyPeer.isEmpty) {
          await db.update(
            'devices',
            {'is_owner': 1},
            where: 'id = ?',
            whereArgs: [ownerDeviceId],
          );
          await db.insert(
              'sync_meta',
              {
                'key': 'workspaceMode',
                'value': 'standalone',
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '13',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v14: الطرد التلقائي + عدم قدرة العضو على الخروج بنفسه ======
    if (from < 14) {
      await _addColumn(db, 'devices', 'expelled_at', "TEXT DEFAULT ''");
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '14',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v15: حالة مزامنة مستقلة لكل عملية (بجانب status الأصلية). ======
    if (from < 15) {
      await _addColumn(
        db,
        'transactions',
        'sync_state',
        "TEXT NOT NULL DEFAULT 'local'",
      );
      await db.insert(
          'sync_meta',
          {
            'key': 'schemaVersion',
            'value': '15',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v16: إصلاح بذرة المستخدم — تحويل manager→admin وإعطاء كل الصلاحيات ======
    if (from < 16) {
      try {
        await db.execute("UPDATE users SET role='admin' WHERE role='manager'");
        await db.execute(
          "UPDATE users SET permissions='add_tx,edit_tx,delete_tx,view_reports,export,manage_backup,manage_users,approve_vouchers' WHERE role='admin' AND (permissions IS NULL OR TRIM(permissions)='')",
        );
      } catch (_) {}
    }
    // ====== v18: ربط الإشعار بالكيان (فتح العملية من الإشعار) ======
    if (from < 18) {
      await _addColumn(db, 'notifications', 'entity_type', "TEXT DEFAULT ''");
      await _addColumn(db, 'notifications', 'entity_id', "TEXT DEFAULT ''");
    }
    // ====== v19: توحيد workspaceMode — 'managed' القديمة تصبح 'host' ======
    if (from < 19) {
      try {
        await db.update('sync_meta', {'value': 'host'},
            where: "key = 'workspaceMode' AND value = 'managed'");
        await db.update('settings', {'value': 'host'},
            where: "key = 'workspaceMode' AND value = 'managed'");
      } catch (_) {}
    }
    // ====== v20: تجزئة SHA-256 لمرفقات العمليات المالية (جلب عبر LAN) ======
    if (from < 20) {
      await _addColumn(
          db, 'transactions', 'attachment_hash', "TEXT DEFAULT ''");
    }
    // ====== v21 (دفعة 57): عزل المساحات + حذف ناعم للدردشة ======
    if (from < 21) {
      await migrateToV21(db);
    }
    // ====== v22 (دفعة 58): اجتثاث LAN — إسقاط op_deliveries وأعمدة الشبكة ======
    if (from < 22) {
      await migrateToV22(db);
    }
    // ====== v27 (تنظيف 2026-10-31): اجتثاث المخزون والمبيعات ======
    // التطبيق صار «دفتر حسابات» خالصًا — تُسقط جداول الأصناف والأقسام
    // والفئات وحركات المخزون وبنود الفواتير نهائيًا من أي قاعدة قديمة.
    // (IF EXISTS: القواعد الجديدة تُنشأ أصلًا بلا هذه الجداول.)
    if (to >= 27) {
      await db.execute('DROP TABLE IF EXISTS transaction_items');
      await db.execute('DROP TABLE IF EXISTS stock_moves');
      await db.execute('DROP TABLE IF EXISTS items');
      await db.execute('DROP TABLE IF EXISTS item_categories');
      await db.execute('DROP TABLE IF EXISTS sections');
    }
    // ====== v17: ضمان المخطط الكامل عند كل فتح (إصلاح قواعد ويندوز الناقصة) ======
    // أي جدول ناقص من بناء سابق يُنشأ، والبذرة idempotent. هذا يغلق نهائيًا
    // خطأ "table workspaces already exists" و"تعذّر تحميل الفئات/الإعدادات".
    await ensureFullSchema(db);
    await db.insert(
        'sync_meta',
        {
          'key': 'schemaVersion',
          // (دفعة 57) كان مثبتاً '17' يدوياً — يتبع _version تلقائياً الآن.
          'value': '$_version',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Migration v4 → v5: إضافة جداول المزامنة + أعمدة workspace/deleted للجداول القديمة.
  /// Migration v20 → v21 (دفعة 57 — التحصين الشامل):
  ///  1) notifications.workspace_id — عزل الإشعارات بين المساحات (كانت
  ///     تتسرب نظرياً عند تبديل المجموعة على نفس الجهاز).
  ///  2) currencies: مفتاح مركّب (code, workspace_id) بدل code وحده —
  ///     تعديل سعر صرف في مجموعة لا يلوّث الأخرى.
  ///  3) messages/conversations: أعمدة deleted_at/deleted_by/sync_state —
  ///     حذف الدردشة يصبح ناعماً قابلاً للمزامنة المتماثلة بين الأجهزة.
  /// عامة (public) لأن ensureFullSchema تستدعيها أيضاً للقواعد الجديدة.
  static Future<void> migrateToV21(Database db) async {
    // 1) عزل الإشعارات.
    await _addColumn(
        db, 'notifications', 'workspace_id', "TEXT NOT NULL DEFAULT 'default'");
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notif_ws ON notifications(workspace_id)');

    // 2) currencies بمفتاح مركّب: SQLite لا يدعم تعديل PK — إعادة بناء.
    //    idempotent: إن كان الجدول الجديد مبنياً (فهرس التحقق موجود) نتخطى.
    final already = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_curr_pk_v21'");
    if (already.isEmpty) {
      await db.transaction((txn) async {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS currencies_v21 (
            code    TEXT NOT NULL,
            workspace_id TEXT NOT NULL DEFAULT 'default',
            name    TEXT NOT NULL,
            symbol  TEXT NOT NULL,
            decimal INTEGER NOT NULL DEFAULT 0,
            rate    REAL NOT NULL DEFAULT 1,
            deleted_at TEXT DEFAULT '',
            PRIMARY KEY (code, workspace_id)
          )''');
        await txn.execute('''
          INSERT OR IGNORE INTO currencies_v21
            (code, workspace_id, name, symbol, decimal, rate, deleted_at)
          SELECT code, COALESCE(workspace_id,'default'), name, symbol,
                 decimal, rate, COALESCE(deleted_at,'')
          FROM currencies''');
        await txn.execute('DROP TABLE currencies');
        await txn.execute('ALTER TABLE currencies_v21 RENAME TO currencies');
        await txn.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_curr_pk_v21 '
            'ON currencies(code, workspace_id)');
      });
    }

    // 3) حذف ناعم للدردشة.
    await _addColumn(db, 'messages', 'deleted_at', "TEXT DEFAULT ''");
    await _addColumn(db, 'messages', 'deleted_by', "TEXT DEFAULT ''");
    await _addColumn(db, 'messages', 'sync_state', "TEXT DEFAULT 'synced'");
    await _addColumn(db, 'conversations', 'deleted_at', "TEXT DEFAULT ''");
    await _addColumn(db, 'conversations', 'deleted_by', "TEXT DEFAULT ''");
    await _addColumn(
        db, 'conversations', 'sync_state', "TEXT DEFAULT 'synced'");
  }

  /// Migration v21 → v22 (دفعة 58 — اجتثاث LAN نهائياً):
  ///  1) إسقاط جدول op_deliveries (تتبع تسليم LAN لكل جهاز) — معيار
  ///     التسليم اليوم سحابي: operations.synced=1 يعني وصلت الجميع.
  ///  2) إعادة بناء devices بلا عمودَي ip_address/port (لا اتصال مباشر
  ///     بين الأجهزة بعد اليوم — Firebase RTDB هو الناقل الوحيد).
  ///  3) تطهير مفاتيح إعدادات LAN التاريخية.
  /// idempotent بالكامل — تُستدعى أيضاً من ensureFullSchema عند كل فتح.
  static Future<void> migrateToV22(Database db) async {
    await db.execute('DROP TABLE IF EXISTS op_deliveries');
    // إعادة بناء devices فقط إن كانت أعمدة LAN ما تزال موجودة.
    final cols = await db.rawQuery('PRAGMA table_info(devices)');
    final names = cols.map((c) => '${c['name']}').toSet();
    if (names.contains('ip_address') || names.contains('port')) {
      await db.transaction((txn) async {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS devices_v22 (
            id             TEXT PRIMARY KEY,
            workspace_id   TEXT NOT NULL,
            name           TEXT NOT NULL DEFAULT '',
            platform       TEXT DEFAULT '',
            app_version    TEXT DEFAULT '',
            last_seen_at   TEXT DEFAULT '',
            last_sync_at   TEXT DEFAULT '',
            pair_token     TEXT DEFAULT '',
            pair_token_exp TEXT DEFAULT '',
            auth_secret    TEXT DEFAULT '',
            revoked_at     TEXT DEFAULT '',
            expelled_at    TEXT DEFAULT '',
            user_id        INTEGER,
            paired_by      INTEGER,
            is_paired      INTEGER NOT NULL DEFAULT 1,
            is_owner       INTEGER NOT NULL DEFAULT 0,
            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL
          )''');
        await txn.execute('''
          INSERT OR IGNORE INTO devices_v22
            (id, workspace_id, name, platform, app_version, last_seen_at,
             last_sync_at, pair_token, pair_token_exp, auth_secret,
             revoked_at, expelled_at, user_id, paired_by, is_paired,
             is_owner, created_at, updated_at)
          SELECT id, workspace_id, name, COALESCE(platform,''),
                 COALESCE(app_version,''), COALESCE(last_seen_at,''),
                 COALESCE(last_sync_at,''), COALESCE(pair_token,''),
                 COALESCE(pair_token_exp,''), COALESCE(auth_secret,''),
                 COALESCE(revoked_at,''), COALESCE(expelled_at,''),
                 user_id, paired_by, COALESCE(is_paired,1),
                 COALESCE(is_owner,0), created_at, updated_at
          FROM devices''');
        await txn.execute('DROP TABLE devices');
        await txn.execute('ALTER TABLE devices_v22 RENAME TO devices');
      });
    }
    // مفاتيح LAN التاريخية في settings — لم يعد يقرؤها أحد.
    try {
      await db.delete('settings',
          where: "key IN ('lanSyncEnabled', 'lastLanSync')");
    } catch (_) {}
  }

  static Future<void> _migrate4to5(Database db) async {
    // 1) إنشاء الجداول الجديدة (workspaces, devices, operations, sync_queue, sync_meta, google_auth).
    await execSchemaScript(db, createSyncSchemaSql);

    // 2) Workspace افتراضي.
    final now = DateTime.now().toIso8601String();
    await db.insert('workspaces', {
      'id': 'default',
      'name': 'متجري',
      'owner_google_id': '',
      'owner_email': '',
      'owner_name': '',
      'created_at': now,
      'updated_at': now,
    });

    // 3) إضافة أعمدة workspace_id / deleted_at للجداول الموجودة (إن لم تكن موجودة).
    const entityTables = [
      'accounts',
      'transactions',
      'vouchers',
      'currencies',
      'categories',
      'users',
      'conversations',
      'messages',
      'activity',
    ];
    for (final t in entityTables) {
      await _addColumn(
        db,
        t,
        'workspace_id',
        "TEXT NOT NULL DEFAULT 'default'",
      );
      if (t != 'activity' &&
          t != 'conversations' &&
          t != 'messages' &&
          t != 'categories') {
        await _addColumn(db, t, 'deleted_at', "TEXT DEFAULT ''");
        await _addColumn(db, t, 'deleted_by', "INTEGER");
        await _addColumn(db, t, 'restore_op_id', "TEXT DEFAULT ''");
      }
    }
    // transaction_items & conversations/messages/activity لا تحتاج soft-delete مستقل (تتبع والديها).

    // 4) فهارس إضافية للأعمدة الجديدة.
    for (final t in [
      'accounts',
      'transactions',
      'vouchers',
      'users',
      'currencies',
    ]) {
      await _tryCreateIndex(
        db,
        'idx_${t}_ws',
        'CREATE INDEX IF NOT EXISTS idx_${t}_ws ON $t(workspace_id)',
      );
      await _tryCreateIndex(
        db,
        'idx_${t}_del',
        'CREATE INDEX IF NOT EXISTS idx_${t}_del ON $t(deleted_at)',
      );
    }

    // 5) إدراج sync_meta مبدئي.
    await db.insert(
        'sync_meta',
        {
          'key': 'schemaVersion',
          'value': '5',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _tryCreateIndex(
    Database db,
    String name,
    String sql,
  ) async {
    // IF NOT EXISTS يجعل العملية آمنة.
    final safe = sql.contains('IF NOT EXISTS')
        ? sql
        : sql.replaceFirst('CREATE INDEX', 'CREATE INDEX IF NOT EXISTS');
    await db.execute(safe);
  }

  /// إضافة عمود إن لم يكن موجودًا — آمنة للتكرار.
  static Future<void> _addColumn(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// البيانات الأولية: العملات الثلاث ومستخدم المدير.
  /// idempotent بالكامل — يمكن استدعاؤها عند كل فتح بأمان (تتجاهل الموجود).
  static Future<void> _seed(Database db) async {
    final now = DateTime.now().toIso8601String();
    for (final c in const [
      ['YER', 'الريال اليمني', 'ر.ي', 0],
      ['USD', 'الدولار الأمريكي', r'$', 2],
      ['SAR', 'الريال السعودي', 'ر.س', 2],
    ]) {
      await db.insert(
        'currencies',
        {
          'code': c[0],
          'name': c[1],
          'symbol': c[2],
          'decimal': c[3],
          'rate': 1.0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    // المدير الافتراضي: أنشئه فقط إن لم يوجد أي مستخدم إطلاقًا
    // (حتى لا نُكرّر المستخدم في قواعد قائمة أو نكتب فوق مستخدم حقيقي).
    final users = await db.rawQuery('SELECT COUNT(*) AS c FROM users');
    final count = (users.isNotEmpty ? users.first['c'] as int? : null) ?? 0;
    if (count == 0) {
      // إصلاح حرج: role كان 'manager' غير موجود في UserRole enum → viewer ويمنع الحفظ.
      // الآن نستخدم 'admin' مع كل الصلاحيات.
      await db.insert('users', {
        'name': 'المدير',
        'role': 'admin',
        'permissions':
            'add_tx,edit_tx,delete_tx,view_reports,export,manage_backup,manage_users,approve_vouchers',
        'is_me': 1,
        'active': 1,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      // قاعدة قائمة: تأكد أن هناك مستخدمًا "أنا" (is_me=1)؛ الأول admin إن وُجد.
      final me = await db.rawQuery(
        "SELECT id FROM users WHERE is_me = 1 AND COALESCE(deleted_at,'') = '' LIMIT 1",
      );
      if (me.isEmpty) {
        final admin = await db.rawQuery(
          "SELECT id FROM users WHERE role = 'admin' AND COALESCE(deleted_at,'') = '' ORDER BY id LIMIT 1",
        );
        if (admin.isNotEmpty) {
          await db.update('users', {'is_me': 1},
              where: 'id = ?', whereArgs: [admin.first['id']]);
        }
      }
    }
    try {
      await db.insert(
        'sync_meta',
        {'key': 'schema_ensured_v', 'value': '$_version'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }
}
