# Nexora Local-First Sync Architecture
# Phase 1: Design Document
# ============================================================

## 1. الوضع الحالي (Baseline)

### 1.1 قاعدة البيانات المحلية
- SQLite عبر sqflite + sqflite_common_ffi (يعمل على أندرويد وويندوز ولينكس).
- الملف: `nexora.db` داخل مجلد التطبيق.
- إصدار المخطط: 4.
- الجداول الحالية (16 جدول):
  - `accounts`, `transactions`, `vouchers`, `currencies`, `categories`,
  - `item_categories`, `items`, `stock_moves`, `transaction_items`,
  - `users`, `conversations`, `messages`, `activity`, `trash`,
  - `notifications`, `templates`, `settings`.

### 1.2 المزامنة السحابية الحالية (`lib/data/cloud_sync.dart`)
- Firebase RTDB REST فقط (PUT/GET).
- يرفع قاعدة البيانات كـ JSON كامل تحت `/codes/<CODE>.json`.
- استراتيجية التعارض: Last-Write-Wins حسب `updatedAt`.
- لا Operation log، لا Queue، لا Realtime، لا Workspace، لا deviceId.
- لا Auto-sync (استدعاء يدوي فقط).

### 1.3 أنظمة الـ Backup الحالية (مكررة)
1. Google Drive backup (`google_drive_service.dart`) — ملف `.nexora`.
2. Cloud Sync (Firebase PUT لقاعدة كاملة) — يلعب دور Backup أيضًا.
3. تصدير/استيراد ملف محلي (File picker) في `backup_screen.dart`.
4. مشاركة عبر واتساب (tx_share) — ليست Backup حقيقي بل للسندات.
5. صفحة `backup_screen.dart` (972 سطر) تجمع هذه الخيارات بواجهة مزدحمة.

### 1.4 المصادقة الحالية
- `google_sign_in` موجود فقط للحصول على OAuth لرفع ملف لـ Drive.
- لا نظام هوية، لا Workspace، لا ربط للمستخدمين المحليين بهوية Google.

### 1.5 سلة المحذوفات (trash)
- موجودة: حذف العناصر ينشئ سجلًا في `trash` مع payload JSON ثم يحذف السجل.
- `restoreFromTrash` موجود لكن لا يسجل `restoredAt`/`restoredBy` ولا ينشئ Operation.

---

## 2. قرارات معمارية نهائية

### 2.1 قاعدة البيانات
- **نحتفظ بـ SQLite** (لا ننتقل لـ Hive/Isar/Drift) لأنها مستقرة وتدعم المعاملات والفهارس وتعمل على جميع المنصات.
- نرفع إصدار المخطط إلى **v5** مع Migration آمن مع auto-backup قبله.

### 2.2 عدم كسر الوظائف الحالية
- كل دوال `Repo` الحالية تبقى بنفس الأسماء والتوقيعات (لا نكسر الشاشات الموجودة).
- نضيف طبقة Operation/Queue **داخل** عمليات الحفظ الحالية، ولا نعيد كتابة الشاشات.

### 2.3 Cloud Backend
- نختار **Firebase Realtime Database** لأنه موجود أصلًا في الكود (عبر REST) ويدعم Realtime ويعمل على Free Tier.
- سنكتب طبقة `CloudSyncService` بشكل abstraction بحيث يمكن استبدالها لاحقًا، ولكن التنفيذ الافتراضي Firebase.
- **لن نضيف Firebase SDK ثقيل**؛ سنستمر في REST (http package الموجود) لأنه أخف وأسهل في البناء دون قفل النظام الأساسي.
- Cloud Sync = Operation-based incremental (نرفع operations الجديدة فقط)، وليس رفع القاعدة كاملة.

### 2.4 LAN Sync
- نضيف **خادم HTTP محلي اختياري** داخل التطبيق على بورت ثابت (مثلاً 43053) يعمل فقط عند تفعيل "Local Sync" من الإعدادات.
- يبث الـ device أحداث العمليات الجديدة عبر HTTP POST على الأجهزة الأخرى في نفس الـ Wi-Fi.
- نكتب abstraction فقط في المرحلة 7؛ الاكتشاف الآلي (mDNS/Broadcast) يُترك للتنفيذ الفعلي لاحقًا (في المرحلة الحالية: إدخال IP الجهاز الآخر يدوياً أو عبر QR).

### 2.5 Google Sign-In
- نحافظ على `google_sign_in` الموجود لكن نوسّع دوره:
  - تسجيل دخول لمرة واحدة (session محفوظة محليًا).
  - الحصول على `idToken` لإثبات الهوية (لا نستخدم Access Token كمعرف دائم).
  - نربط Google sub (subject) كـ `ownerId` للـ Workspace.
- **لا نستخدم Google Drive كقاعدة بيانات**. يبقى خيار Backup ثانوي يمكن إزالته/إبقاؤه بعد التنظيف.

### 2.6 QR Pairing
- QR يحتوي فقط على: `ws://<ip>:43053/pair?token=<8-char-one-time-token>&workspace=<workspaceId>`.
- الـ token صلاحيته 5 دقائق ويُستخدم لمرة واحدة؛ لا يحوي أي أسرار طويلة الأمد.
- بعد المسح، يتبادل الجهازان deviceId عبر HTTP محلي ويضيف كل منهما الآخر إلى قائمة الأجهزة الموثوقة.

### 2.7 التخزين المحلي أولاً (القاعدة غير قابلة للتفاوض)
- جميع دوال الحفظ (`saveAccount`, `saveTx`, `saveItem`, `saveUser`...) تحفظ محليًا ضمن معاملة SQLite واحدة.
- بعد نجاح المعاملة المحلية، تُنشأ Operation داخل نفس المعاملة ثم تُضاف إلى sync_queue.
- بعد الخروج من المعاملة، تعيد الدالة القيمة للمستخدم فورًا (تغلق النافذة، تحدّث الواجهة).
- في الخلفية: `SyncEngine.processQueue()` يلتقط العمليات PENDING ويرسلها.
- أي فشل شبكي لا يؤثر على نتيجة الحفظ (سيبقى في Queue).

---

## 3. مخطط قاعدة البيانات الجديد (v5)

### 3.1 جداول جديدة تُضاف في Migration v4 → v5

#### 3.1.1 جدول `workspaces`
يمثل قاعدة بيانات المتجر/الشركة.
```sql
CREATE TABLE workspaces (
  id           TEXT PRIMARY KEY,          -- UUID
  name         TEXT NOT NULL DEFAULT '',
  owner_google_id TEXT DEFAULT '',        -- Google sub (subject)
  owner_email  TEXT DEFAULT '',
  owner_name   TEXT DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
```
- عند أول تشغيل بعد Migration، يُنشأ workspace افتراضي محلي:
  `id = uuid()`, `name = 'متجري'`, `owner_google_id = ''` حتى يربط المستخدم بحساب Google لاحقًا.
- `workspace_id` سيتم إضافته كعمود إلى كل الجداول الموجودة التي تحوي بيانات المستخدم، ولكنه في المرحلة الحالية سيكون دائمًا `default_workspace` لتبسيط الهجرة (لأن التطبيق الحالي single-tenant). يمكن لاحقًا دعم multi-workspace.

#### 3.1.2 جدول `devices`
```sql
CREATE TABLE devices (
  id             TEXT PRIMARY KEY,        -- 'DEVICE-xxxxxxxx'
  workspace_id   TEXT NOT NULL,
  name           TEXT NOT NULL DEFAULT '',
  platform       TEXT DEFAULT '',          -- android/windows/linux
  app_version    TEXT DEFAULT '',
  ip_address     TEXT DEFAULT '',
  port           INTEGER DEFAULT 0,
  last_seen_at   TEXT DEFAULT '',
  last_sync_at   TEXT DEFAULT '',
  pair_token     TEXT DEFAULT '',         -- token مؤقت للاقتران
  pair_token_exp TEXT DEFAULT '',         -- انتهاء صلاحية token
  is_paired      INTEGER NOT NULL DEFAULT 1,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
);
```

#### 3.1.3 جدول `operations` — Operation Log دائم
```sql
CREATE TABLE operations (
  id            TEXT PRIMARY KEY,          -- UUID (operationId)
  device_id     TEXT NOT NULL,
  workspace_id  TEXT NOT NULL,
  user_id       INTEGER,                   -- users.id محلي
  entity_type   TEXT NOT NULL,             -- account/tx/item/stock_move/voucher/user/setting
  entity_id     TEXT NOT NULL,             -- المعرّف المحلي
  op_type       TEXT NOT NULL,             -- create/update/delete/restore
  version       INTEGER NOT NULL DEFAULT 1,
  parent_op_id  TEXT DEFAULT '',           -- لعمليات restore
  payload       TEXT NOT NULL,             -- JSON snapshot الكامل (للإعادة والتعارض)
  patch         TEXT DEFAULT '',           -- JSON diff (اختياري، للتدقيق)
  device_time   TEXT NOT NULL,             -- وقت الجهاز
  server_time   TEXT DEFAULT '',           -- وقت الخادم عند المزامنة
  timestamp     TEXT NOT NULL,             -- وقت إنشاء العملية
  synced        INTEGER NOT NULL DEFAULT 0,
  UNIQUE(id)
);
CREATE INDEX idx_ops_entity ON operations(entity_type, entity_id);
CREATE INDEX idx_ops_time   ON operations(timestamp);
CREATE INDEX idx_ops_sync   ON operations(synced, timestamp);
```

**Idempotency**: `operations.id` هو UUID يُولَّد محليًا قبل الحفظ. عند إعادة إرسال نفس العملية أو وصولها من جهاز آخر، يتم تجاهلها إذا كان `id` موجودًا مسبقًا.

#### 3.1.4 جدول `sync_queue`
```sql
CREATE TABLE sync_queue (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  operation_id  TEXT NOT NULL UNIQUE,
  status        TEXT NOT NULL DEFAULT 'pending', -- pending/syncing/synced/failed
  target        TEXT NOT NULL DEFAULT 'cloud',   -- cloud / lan / device:<deviceId>
  attempts      INTEGER NOT NULL DEFAULT 0,
  last_error    TEXT DEFAULT '',
  next_try_at   TEXT DEFAULT '',                 -- backoff
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE
);
CREATE INDEX idx_queue_status ON sync_queue(status, next_try_at);
```

#### 3.1.5 جدول `sync_meta`
يخزن رؤوس المزامنة لمنع التكرار:
```sql
CREATE TABLE sync_meta (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
-- سيُستخدم لحفظ: last_clock (Lamport/hybrid logical clock), last_server_cursor, device_id, workspace_id, ...
```

#### 3.1.6 جدول `google_auth`
يحفظ جلسة Google بشكل آمن (idToken, refresh metadata فقط):
```sql
CREATE TABLE google_auth (
  id              INTEGER PRIMARY KEY CHECK (id=1),
  google_id       TEXT DEFAULT '',
  email           TEXT DEFAULT '',
  display_name    TEXT DEFAULT '',
  photo_url       TEXT DEFAULT '',
  id_token        TEXT DEFAULT '',   -- لا يُرسل للخوادم غير Google
  signed_in_at    TEXT DEFAULT '',
  updated_at      TEXT DEFAULT ''
);
```

### 3.2 أعمدة جديدة على الجداول الموجودة
- `accounts/workspace_id TEXT DEFAULT 'default'`
- `transactions/workspace_id TEXT DEFAULT 'default'`
- `vouchers/workspace_id TEXT DEFAULT 'default'`
- `items/workspace_id TEXT DEFAULT 'default'`
- `stock_moves/workspace_id TEXT DEFAULT 'default'`
- `item_categories/workspace_id TEXT DEFAULT 'default'`
- `users/workspace_id TEXT DEFAULT 'default'`
- `transaction_items/workspace_id TEXT DEFAULT 'default'`
- ولكل جدول بيانات مستخدم أيضًا: `deleted_at TEXT DEFAULT ''`, `deleted_by INTEGER`, `restore_operation_id TEXT DEFAULT ''`.
  (هذا يحوّل الحذف الحالي من hard-delete إلى soft-delete حقيقي. جدول `trash` الحالي سيُبقى ولكنه سيتم إعادة ملئه من `deleted_at IS NOT NULL` بدلاً من الاحتفاظ به كسجل مستقل.)

### 3.3 تحسين استراتيجية الحذف
- `deleteAccount`, `deleteTx`, `deleteItem`, `deleteVoucher`... تصبح تحدّث `deleted_at` بدل `DELETE`.
- استعلامات القراءة تضيف `WHERE deleted_at = ''` (نضيفها إلى استعلامات repo الحالية).
- الاستعادة (restore) تنشئ Operation جديدة من النوع `restore` ولا تعدّل `created_at` الأصلي.
- `emptyTrash()` يحذف فعليًا العناصر التي مضى عليها أكثر من 30 يومًا في سلة المهملات (أو فورًا إذا حذفها المستخدم نهائيًا).

---

## 4. خطة Migration (v4 → v5)

### 4.1 خطوات آمنة
1. **Auto-backup قبل Migration** (دالة جديدة `_preMigrationBackup()`) تُصدّر قاعدة البيانات كـ JSON إلى ملف مؤقت داخل مجلد التطبيق.
2. داخل معاملة SQLite واحدة:
   - إنشاء الجداول الجديدة (`workspaces`, `devices`, `operations`, `sync_queue`, `sync_meta`, `google_auth`).
   - إدخال Workspace افتراضي.
   - توليد deviceId ثابت (يُحفظ في `sync_meta` أو في settings إن لم يكن موجودًا).
   - تسجيل هذا الجهاز في `devices` (is_paired=1).
   - إضافة أعمدة `workspace_id`, `deleted_at`, `deleted_by`, `restore_operation_id` إلى الجداول الموجودة (عبر `ALTER TABLE ... ADD COLUMN` مع فحص وجود العمود قبله).
   - فهرسة الأعمدة الجديدة.
3. **تحقق بعد Migration**:
   - عدد الحسابات قبل/بعد.
   - عدد العمليات قبل/بعد.
   - عدد الأصناف قبل/بعد.
   - عدد حركات المخزون قبل/بعد.
   - عدد السندات قبل/بعد.
4. إذا نجح كل شيء: حذف ملف الـ backup المؤقت.
5. إذا فشل أي خطوة: rollback عبر `throw` (المعاملة تُلغى تلقائيًا)، وإبقاء ملف الـ backup لاستعادة يدوية.

### 4.2 عدم فقدان البيانات
- لن يتم حذف أي بيانات قديمة.
- جدول `trash` القديم يُهجر: سنجعل دالة `trash()` تقرأ من الجداول الرئيسية باستخدام `deleted_at <> ''` بدلاً من `trash` القديم، مع ترحيل السجلات القديمة إلى Operations كعمليات `delete` تاريخية إن أمكن.
- سجل `activity` يُبقى دون تغيير (للتوافق مع الشاشات).

---

## 5. طبقات المزامنة الجديدة

### 5.1 Operation Types
- `create` — إنشاء كيان جديد.
- `update` — تعديل كيان.
- `delete` — حذف ناعم.
- `restore` — استعادة من سلة المهملات.
- (تُضاف لاحقًا: `settings_update` لتغيير إعدادات عامة).

### 5.2 Operation IDs
- تُولَّد محليًا عبر UUID v4 قبل الحفظ في SQLite.
- الجهاز المُرسِل يضع أيضًا `device_id`.
- عند ورود نفس `operation.id` من أي قناة (Cloud/LAN/QR) يُتجاهل إذا كان موجودًا مسبقًا (idempotent).

### 5.3 Sync Queue Logic
- عند إنشاء Operation، تُضاف صفوف في `sync_queue` بـ status='pending' لكل target مُفعّل (cloud وجميع أجهزة LAN المقترنة).
- `SyncEngine.processQueue()` تعمل في isolate/background بعد الحفظ:
  - تلتقط حتى 20 عملية PENDING مرتبة حسب `created_at`.
  - تتحول حالتها إلى `syncing` وتزيد `attempts`.
  - تحاول الإرسال:
    - للـ Cloud عبر REST PUT (Firebase) تحت `/workspaces/<wsid>/operations/<opId>.json`.
    - لأجهزة LAN عبر HTTP POST `http://<ip>:<port>/ops`.
  - عند النجاح: status='synced'، تُحدّث `operations.synced=1` للـ target المعني، `server_time` إن وُجد.
  - عند الفشل: status='failed'، `next_try_at = now + backoff(attempts)` (exponential: 5s, 30s, 2m, 10m, 1h, 4h).
- عند بدء التطبيق: استدعاء `processQueue()` لالتقاط القديم.
- مراقب الاتصال (ConnectivityListener بسيط عبر `http` pinging للخادم أو عبر الحزمة `connectivity_plus`): عند عودة الاتصال يعيد `processQueue()`.

### 5.4 Conflict Resolution
- نستخدم **Operation Log + Lamport Clock بسيط**:
  - كل operation تحمل `version` يتم زيادته محليًا (1 + أعلى version معروف للـ entityId).
  - عند وصول operation من جهاز آخر، نتحقق:
    - إذا كان `operation.id` موجودًا مسبقًا → تجاهل (idempotent).
    - إذا كان `entityId` غير موجود و op_type = create → تطبيق.
    - إذا كان `entityId` موجودًا و version > النسخة المحلية → تطبيق.
    - إذا كان version == النسخة المحلية و device_id مختلف → تعارض، نضع العملية في جدول `conflicts` (لإضافته لاحقًا؛ في المرحلة الحالية نعرضها للمستخدم).
    - إذا كان version < النسخة المحلية → تُعتبر قديمة، تُسجل في السجل دون تطبيق.
- نستخدم payload كـ snapshot كامل حتى يمكن إعادة بناء الكيان دون اعتماد على ترتيب الشبكة.

### 5.5 ضمان Local-First
- داخل `Repo.saveXxx()`:
  1. افتح `db.transaction`.
  2. INSERT/UPDATE في الجدول الرئيسي.
  3. سجّل في `operations`.
  4. أضف إلى `sync_queue` (status=pending).
  5. اكتب `activity` إن لزم.
  6. أغلق المعاملة (COMMIT).
  7. أعد المعرّف/الكائن للمستدعي.
- بعد إرجاع التحكم، يقوم Riverpod Provider بتحديث الحالة من قاعدة البيانات المحلية (الواجهة تتحدث فورًا).
- `SyncEngine.schedule()` يُستدعى بعد الـ COMMIT (غير `await` على أي استدعاء شبكة).

---

## 6. Google Auth Flow الجديد
- زر "تسجيل الدخول بـ Google" في قسم المزامنة.
- يستدعي `GoogleSignIn.signIn()` مع نطاقات أقل: `email`, `openid`, `profile` (لا نحتاج drive.file في هذا المسار).
- يحفظ بيانات الحساب في جدول `google_auth`.
- يحاول استعادة الجلسة عبر `signInSilently` عند تشغيل التطبيق (بدون إزعاج المستخدم).
- بعد تسجيل الدخول:
  - إذا لم يكن هناك Workspace مرتبط، ينشأ Workspace جديد مع `owner_google_id = google.sub`.
  - إذا كان هناك Workspace محلي غير مرتبط، يربطه.
- تسجيل الخروج لا يحذف البيانات المحلية — فقط يوقف الـ Cloud Sync.

---

## 7. LAN Sync (طبقة abstract)
- واجهة `LocalSyncTransport`:
  - `Future<void> advertiseDevice()` (بث بسيط UDP/HTTP على الشبكة).
  - `Future<void> sendOperation(String deviceIp, int port, Operation op)`.
  - `Stream<Operation> incomingOperations()` (خادم HTTP محلي).
- التنفيذ الأولي (`HttpLocalSyncTransport`):
  - يستخدم خادم HTTP محليًا عبر `dart:io` `HttpServer.bind('0.0.0.0', 43053)` يُشغَّل عند تفعيل "Local Sync".
  - يقبل POST على `/ops` بعمليات JSON.
  - نقطة `/pair` للاقتران عبر QR.
- الاكتشاف التلقائي (UDP broadcast/mDNS) يُترك كتحسين لاحق؛ في المرحلة الحالية الاقتران يمر عبر QR يحتوي على IP+port+token المؤقت.

---

## 8. QR Pairing Flow
1. المستخدم يضغط "ربط جهاز جديد" في الجهاز الرئيسي.
2. يُولَّد `pair_token` من 8 أحرف عشوائية صالح لمدة 5 دقائق ويُحفظ في `devices.pair_token/pair_token_exp` في صف مؤقت.
3. يُنشأ QR يحتوي على: `nexora://pair?ws=<workspaceId>&ip=<localIp>&port=43053&tok=<pairToken>`.
4. الجهاز الجديد يمسح QR بكاميراه (نستخدم `mobile_scanner` الموجود).
5. الجهاز الجديد يرسل POST إلى `http://<ip>:<port>/pair` مع deviceId واسم الجهاز.
6. الجهاز الرئيسي يتحقق من token، ثم يسجل الجهاز الجديد في `devices`، ويردّ بحالة نجاح + قائمة operations الحديثة.
7. بعد الاقتران، كلا الجهازين يرسلان operations الجديدة إلى بعضهما عبر LAN.
8. لا يتم وضع أي access token طويل الأمد داخل QR.

---

## 9. Backup/Recovery الموحد
- بعد التنظيف يبقى لدينا **نظامان فقط** للنسخ الاحتياطي:
  1. **Cloud Sync** (تفعيله = نسخة سحابية حية من العمليات).
  2. **Local Backup/Restore** (تصدير/استيراد ملف `.nexora` محلي).
- Google Drive backup يُبقى كخيار إضافي داخل نفس قسم Local Backup (رفع ملف النسخة المحلية إلى Drive) — لا يُعامل كنظام مزامنة.
- Cloud Sync القديم (رفع القاعدة كاملة) يُحذف من واجهة المستخدم ويستبدل بـ Operation-based sync.
- صفحة `backup_screen.dart` تُستبدل بقسم واحد في `settings_screen.dart`.

---

## 10. التغييرات المقترحة على مستوى الملفات

### ملفات جديدة
- `lib/data/sync/operation.dart` — Operation model + OperationType + serialization.
- `lib/data/sync/device_id.dart` — توليد/حفظ deviceId ثابت.
- `lib/data/sync/workspace_service.dart` — Workspace bootstrap واختيار Workspace الحالي.
- `lib/data/sync/sync_queue.dart` — إدارة الطابور + retry/backoff.
- `lib/data/sync/sync_engine.dart` — Process queue + الاتصال بخدمات الـ transports.
- `lib/data/sync/conflict_resolver.dart` — كشف/حل التعارض.
- `lib/data/sync/cloud_firebase_transport.dart` — تنفيذ Cloud عبر Firebase REST (incremental ops).
- `lib/data/sync/lan_http_transport.dart` — خادم وعميل HTTP المحلي.
- `lib/data/sync/backup_service.dart` — تصدير/استيراد موحد مع auto-backup قبل Migration.
- `lib/data/sync/google_auth_service.dart` — تسجيل الدخول Google + session.
- `lib/data/sync/qr_pairing.dart` — إنشاء/فحص QR pairing token.
- `lib/ui/sync_status_indicator.dart` — ويدجت حالة المزامنة (🟢🟡🟠🔴⚪).
- `lib/ui/sync_settings_section.dart` — قسم موحد في الإعدادات.
- `test/sync_*_test.dart` — اختبارات عملية للعمليات.

### ملفات تُعدّل
- `lib/core/database.dart` — إضافة جداول v5 + Migration v4→v5 + ميثاق جديد للجداول.
- `lib/core/models.dart` — إضافة `workspaceId` و `deletedAt` للنماذج (اختياري مع قيمة افتراضية null/empty لعدم كسر الكود الحالي).
- `lib/data/repository.dart` — تحويل عمليات الحفظ لإدخال Operation في نفس المعاملة + soft delete + تحديث استعلامات القراءة.
- `lib/main.dart` — تهيئة deviceId/workspace، تشغيل SyncEngine، تشغيل LAN server عند الإعداد.
- `lib/ui/settings_screen.dart` — إضافة قسم موحد للمزامنة والنسخ الاحتياطي.
- `lib/ui/home_shell.dart` — إضافة SyncStatusIndicator في شريط الحالة.

### ملفات تُحذف أو تُزال مراجعها
- `lib/ui/backup_screen.dart` — تحل محلها قسم في settings_screen.
- `lib/data/cloud_sync.dart` القديم (رفع القاعدة كاملة) — يُستبدل بـ `cloud_firebase_transport.dart`.
- المراجع إلى `backup_screen.dart` في التنقل/الإعدادات تحول إلى قسم الإعدادات.
- Google Drive backup يبقى كخيار "رفع نسخة محلية إلى Drive" لكن لا يكون في الواجهة الرئيسية للمزامنة.

---

## 11. الخدمات الخارجية والإعدادات المطلوبة لاحقًا من المستخدم
- **Firebase Realtime Database URL**: (مثلاً `https://<project>.firebaseio.com`) يُدخل في الإعدادات أو يُقرأ من إعداد ثابت. لا نحتاج google-services.json لأننا نستخدم REST فقط.
- **Google OAuth client IDs**: موجودة أصلًا في `google_drive_service.dart` للويب/أندرويد/آي أو إس — سنعيد استخدامها لتسجيل الدخول العام.
- لا حاجة لـ Firebase CLI للبناء (REST فقط).

---

## 12. اختبارات المرحلة الأولى
- اختبارات منطقية في `test/` (بدون محاكي):
  - توليد deviceId ثابت.
  - Migration v4→v5 على قاعدة بيانات في الذاكرة (عدد السجلات قبل/بعد).
  - إنشاء Operation + إضافتها للـ Queue في نفس المعاملة.
  - Idempotency: نفس operationId لا يُنفذ مرتين.
  - Soft delete + restore.
  - Backup export/import ملف JSON.
  - Retry backoff logic.
  - Conflict detection بواسطة version/deviceId.

---

## 13. المخاطر والقيود في هذه المرحلة
- بدون Flutter SDK لن يمكن تشغيل اختبارات `flutter test` حتى المرحلة التي نقرر فيها تنزيل Flutter. سأبدأ المراحل الأولى بالكتابة الصحيحة، ثم أثبّت Flutter في المرحلة 9 للتشغيل النهائي والاختبارات — لتقليل وقت شغل القرص.
- في الحاوية لا يمكن تشغيل أندرويد/ويندوز فعليًا أو شبكة LAN حقيقية، لذلك:
  - سأكتب اختبارات وحدة (unit tests) منطقية.
  - لن أدّعي اختبار LAN Sync أو Cloud Sync مع Firebase حقيقي.
- Conflict resolution في المرحلة الأولى سيكتشف التعارض ويسجله؛ واجهة حل التعارض التفاعلية يمكن إضافتها لاحقًا (حاليًا "آخر version أعلى يفوز" مع حفظ كلا النسختين في سجل العمليات).

---

## 14. المخرجات النهائية للمرحلة 1
- [x] تحليل كامل للبنية الحالية.
- [x] وثيقة معمارية (هذا الملف: `docs/sync-architecture.md`).
- [x] خطة Migration v4→v5.
- [x] قائمة الملفات الجديدة/المعدلة/المحذوفة.
- [x] تحديد الخدمات الخارجية المطلوبة من المستخدم لاحقًا.
- [x] تحديد المخاطر والقيود بوضوح.

## 15. حالة الموارد بعد المرحلة 1
- القرص: 4.1G مستخدم / 20G متاح (لم يتم تنزيل أي أدوات إضافية بعد).
- RAM: 550M مستخدم / 1.4G متاح.
- المشروع: 8.9M — كما هو، لم تُنشأ أي build artifacts أو caches.
- لم يتم تعديل أي ملف Dart بعد (هذه المرحلة تصميمية فقط).

## 16. ما تحتاجه المرحلة التالية (PHASE 2)
- لا حاجة لتنزيل Flutter SDK بعد — سنكتب الملفات الجديدة (operation, sync_queue, device_id, workspace_service) كنصوص Dart جاهزة، ثم نعدّل `database.dart` و`repository.dart` لإضافة الجداول وربط Operations بعمليات الحفظ.
- لن ننشئ build artifacts في المرحلة 2؛ سنتحقق من الصحة النحوية عبر Dart analyzer لاحقًا عندما يكون Flutter مثبتًا.
