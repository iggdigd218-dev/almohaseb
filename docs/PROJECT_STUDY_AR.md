# دراسة تقنية شاملة لمشروع «مدير الحسابات» (nexora_app)
**تاريخ الدراسة:** 2026-09-09 — عند الإصدار 3.31.1+54 (commit 572d507)
**المنهج:** تتبّع فعلي للكود (وليس أسماء الملفات/التعليقات): تتبعت مسار الحفظ → التسجيل → الطابور → النقل → التطبيق على الجهاز المستقبل، وفحصت مخطط قاعدة البيانات جدولاً جدولاً.

---

## 1. فكرة المشروع ووظيفته الأساسية

تطبيق Flutter عربي (RTL) لإدارة **سجل المبيعات والديون** لمحل/مؤسسة صغيرة:
- دفتر حسابات (عملاء/موردين/حسابات عامة) بعمليات مالية مُوقعة (له/عليه/قبض/صرف...).
- نقطة بيع (POS) بفواتير أصناف، ومخزون، وسندات، وتقارير.
- **مجموعة أجهزة متزامنة**: جهاز مدير + أجهزة أعضاء بأدوار وصلاحيات، تتزامن فورياً عبر الشبكة المحلية (LAN) وعبر السحابة (Firebase RTDB) بلا خادم وسيط خاص.
- الحزمة: `com.nexora.eradata` — يعمل على أندرويد وويندوز (CI يبني APK و EXE).

---

## 2. الأقسام والميزات الموجودة حالياً

| القسم | الشاشة | أبرز الوظائف |
|---|---|---|
| الرئيسية | dashboard_screen | ملخصات، وصول سريع، تحية موقوتة |
| المبيعات POS | pos_screen | فاتورة أصناف، باركود، نقدي/آجل/جزئي، خصم، سند تلقائي |
| الحسابات | accounts_screen + account_detail + account_form | عملاء/موردون/عام، كشف حساب، حد ائتمان، صور |
| العمليات | transactions_screen + tx_form | 8 أنواع عمليات، مرفقات، مشاركة واتساب/صورة إيصال |
| السندات | vouchers_screen + voucher_doc | قبض/صرف/قيد/تحويل، ترقيم تسلسلي، PDF/صورة |
| المخزون | inventory_screen | أصناف + فئات أصناف + حركات مخزون + حد أدنى |
| العملات | currencies_screen | عملات متعددة بأسعار صرف |
| التقارير | reports_screen | أرصدة، ديون، حركة، تصدير |
| الدردشة | chat_screen (1:1 محلية) + group_chat_screen (متزامنة) | نص + مرفقات (صور/فيديو/صوت/ملفات ≤6MB) + تسجيل صوتي |
| إدارة المجموعة | group_management_screen + devices_screen + users_screen | اقتران QR محلي، دعوة سحابية، أدوار، طرد/حظر، نقل ملكية، وكيل |
| المزامنة | sync_ops_screen + sync_status_indicator + sync_settings_section + cloud_sync_section | قائمة عمليات معلقة/فاشلة، عدّاد تسليم لكل جهاز، إلغاء |
| النسخ الاحتياطي | backup_screen | ملف محلي JSON + Google Drive، قيود مجموعة |
| سلة المهملات | trash_screen | استرجاع متزامن عبر الأجهزة |
| سجل النشاط | activity_screen | من فعل ماذا ومتى |
| الإعدادات | settings_screen + appearance + update_section | هوية المؤسسة، أصوات، قفل، تحديث تلقائي، فرمتة المدير |
| التحديث الذاتي | update_service + update_installer | one-click: version.json من GitHub → تنزيل APK/EXE → شاشة تثبيت |

---

## 3. هيكل المشروع والملفات المهمة

**77 ملف Dart، ~35,700 سطر.** ثلاث طبقات: `core/` (نماذج وأدوات) ← `data/` (مستودع + مزامنة) ← `ui/` (شاشات Riverpod).

### core/
- `database.dart` (1054): مخطط SQLite كاملاً + ترقيات آمنة (idempotent) + `AppDatabase.instance` singleton.
- `models.dart` (1000): Tx, Account, Voucher, AppUser, ChatMessage, InvoiceLine… + `UserRole` + `kPerms`.
- `accounting.dart`: `OpType` (8 أنواع عمليات مالية)، `AccountKind`، العملات الافتراضية.
- `ids.dart`: **معرّفات Snowflake 63-bit** `newGlobalId()` — (ملي ثانية 43b + بصمة جلسة 12b + عدّاد 8b) لمنع تصادم AUTOINCREMENT بين الأجهزة.
- `sfx.dart`: أصوات/اهتزاز عبر MethodChannel أندرويد (vibrate بمدة، systemNotify بقناة إشعارات نظام) وfallback بـ SystemSound.
- `security.dart`: بصمة/قفل local_auth + هاش كلمات مرور SHA-256 بملح ثابت `nexora::`.
- `keep_alive_service.dart`: خدمة يقظة (foreground service + wake lock) عبر Kotlin.
- `app_version.dart`: kAppVersion/kAppBuild + مقارنة SemVer للتحديث.

### data/
- `repository.dart` (3329): **قلب التطبيق** — كل CRUD يمر منه: تحقق صلاحية `_ensureCan` → معاملة SQLite → `SyncRecorder.record` داخل نفس المعاملة (ذرّي).
- `providers.dart` (1067): Riverpod providers (syncOps، counts، presence، unread…).
- `cloud_sync.dart`: نسخة احتياطية سحابية كاملة (push/pull JSON واحد بكود) — نظام مستقل عن مزامنة العمليات.
- `google_drive_service.dart`: رفع/جلب نسخ عبر Drive API (scope: drive.file + appdata).
- `update_service.dart` + `update_installer.dart`: فحص version.json وتثبيت التحديث.

### data/sync/ (نظام المزامنة)
- `operation.dart`: `SyncOperation` + `EntityKind` (12 كياناً) + `OpKind` (create/update/delete_/restore/settings) + `SyncStatus`.
- `recorder.dart`: تسجيل العملية + إدراج أهداف الطابور (cloud/lan) حسب الإعدادات.
- `sync_queue.dart`: عمليات الطابور (pickPending/markSynced/markFailed/backoff) + استثناء الكيانات الصامتة (message/conversation) من العدادات.
- `sync_engine.dart` (711): المحرك — مؤقتات دورية + معالجة طابور + إنقاذ backfill + مصالحة roster + سحب سحابي.
- `lan_http_transport.dart` (1422): خادم HTTP محلي (منفذ 43053) + عميل بث، اقتران، لقطة كاملة، roster.
- `cloud_firebase_transport.dart`: PUT/GET REST مباشرة إلى Firebase RTDB + مستمع SSE للحظية.
- `cloud_join.dart`: دعوة سحابية (لقطة + توكن 24h) + انضمام بمسح كامل + roster سحابي.
- `apply_remote.dart`: تطبيق العمليات الواردة (create/update/delete/restore + مرآة السلة + مرفقات دردشة).
- `conflict_resolver.dart`: حسم التعارض بالنسخة ثم الطابع الزمني ثم deviceId (حتمي عبر الأجهزة).
- `presence_service.dart`: مناداة `/presence` كل 3 ثوانٍ لكل قرين.
- `backup_service.dart`: تصدير/استيراد JSON قبل الهجرات.

### أندرويد (Kotlin)
- `MainActivity.kt`: قنوات Method (اهتزاز/إشعار نظام/واتساب/تثبيت تحديث/أذونات) — `KeepAliveService.kt` + `BootReceiver.kt` للبقاء حياً.

---

## 4. التقنيات والمكتبات

- **Flutter 3.35.4 / Dart 3** — منصات: أندرويد + ويندوز.
- **flutter_riverpod** لإدارة الحالة، **sqflite + sqflite_common_ffi** (ويندوز/اختبارات).
- pdf + printing (سندات)، qr_flutter + mobile_scanner (اقتران/باركود)، local_auth (بصمة)، google_sign_in، http، crypto، share_plus، file_picker، image_picker، flutter_contacts، url_launcher، math_expressions (آلة حاسبة).
- **بلا أي Firebase SDK** — التعامل مع RTDB عبر REST خام (http PUT/GET + SSE عبر dart:io).
- CI: GitHub Actions — verify (analyze+test) + APK (مع version.json للتحديث الذاتي) + Windows EXE.

---

## 5. تخزين البيانات: SQLite — 24 جدولاً

**جداول الأعمال:** accounts، transactions (CHECK amount>0)، transaction_items (أسطر الفواتير)، vouchers، currencies، categories (تصنيفات حسابات)، item_categories، items، stock_moves، users، conversations، messages، activity، trash، notifications، templates، settings (key/value — تشمل هوية المؤسسة والعدادات والإعدادات).

**جداول المزامنة:** workspaces، devices (أسرار الاقتران auth_secret + is_owner + revoked/expelled)، operations (سجل كل عملية Event-Log)، sync_queue (UNIQUE(operation_id,target))، op_deliveries (PK مركب operation_id+device_id)، sync_meta (workspaceMode/lastCloudTs…)، google_auth (صف واحد id=1).

**العلاقات الرئيسية:** transactions→accounts (CASCADE على account/from/to)، transaction_items→transactions (CASCADE)، stock_moves→items (CASCADE)، messages→conversations (CASCADE)، devices→workspaces (CASCADE — **مصدر مطب الانضمام السحابي المُعالج**)، sync_queue→operations (CASCADE). PRAGMA foreign_keys = ON دائماً.

**الحذف ناعم** في كل جداول الأعمال (`deleted_at` + `deleted_by` + `restore_op_id`) + نسخة JSON في trash.

---

## 6. سجل الحسابات والديون — كيف تُسجَّل العملية المالية فعلياً

تتبعت `saveTx` (repository.dart:624):
1. تحقق مدخلات: مبلغ > 0 ومنتهٍ، عملة، حسابا تحويل مختلفان + سعر صرف موجب، حساب إلزامي إلا للأنواع النقدية المجهولة (accountId=0 → NULL).
2. تحقق صلاحية `add_tx`/`edit_tx` بمهلة 4 ثوانٍ (فشل التحقق = رفض، لا سماح صامت).
3. **معاملة واحدة ذرّية**: توليد مرجع تسلسلي للعرض (عدّاد في settings + MAX(reference) حماية) → إدراج بمعرّف `newGlobalId()` → أسطر الفاتورة → `SyncRecorder.record` (operations + sync_queue) → activity. أي فشل يرجع كل شيء.
4. `sync_state` = synced في الوضع المستقل، pending داخل مجموعة، ويتحدث syncing/synced/failed أثناء الدفع.

**الرصيد** يُحتسب تجميعياً من العمليات غير المحذوفة (`deleted_at=''`) + الرصيد الافتتاحي؛ الاتجاه من نوع العملية (debit عليه / credit له / inflow / outflow / تحويل بطرفين وسعر صرف).

---

## 7. نظام المبيعات والفواتير (POS)

- سلة أصناف (بحث + باركود) → خصم → ثلاثة أوضاع دفع: **نقدي** (بلا حساب)، **آجل** (دين على العميل)، **جزئي** (عمليتان: دين كامل + دفعة مقدمة بوصف يتضمن المتبقي).
- رقم الفاتورة تسلسلي رقمي بحت (للعرض) منفصل عن المعرف العالمي.
- الحفظ ينشئ: transaction + transaction_items + حركات مخزون (خصم كميات) + سند تلقائي عند القبض — كلها بعمليات مزامنة مستقلة تصل الأجهزة الأخرى.
- الإيصال: صورة receipt_image أو PDF أو مشاركة واتساب بقالب.

---

## 8. الأصناف والمخزون

- items (كمية، حد أدنى min_quantity، سعر شراء/بيع، وحدة، صورة، فئة) + item_categories + stock_moves (in/out/adjust مع ربط اختياري بحساب).
- البيع من POS يولّد stock_move خصماً تلقائياً؛ الكمية الحالية محفوظة في العمود quantity وتتحدث مع كل حركة.
- كل تعديلات المخزون تُسجَّل عمليات مزامنة (EntityKind.item/stockMove/itemCategory) وتصل لكل الأجهزة.

---

## 9. نظام الدردشة

**نوعان مختلفان فعلياً:**
1. **دردشة المجموعة** (conversation ثابتة id=777000111): كل رسالة تُدرج في messages ثم تُسجَّل عملية `EntityKind.message` تمر بنفس ممر مزامنة الأموال (LAN + Cloud). المرفقات: الملف يُحفظ محلياً في documents/chat_media ويُضمَّن **base64 داخل حمولة العملية** (حد 6MB)؛ المستقبل يعيد بناء الملف ويوجّه payload لمساره المحلي. المستقبل ينشئ المحادثة تلقائياً إن غابت (أمان FK). الإشعار: callback واحد `LanSyncService.onChatMessage` يُستدعى من خادم LAN عند التطبيق، ومن `CloudFirebaseTransport.pull` (أُضيف في 3.31.1) — يشغّل صوتاً + إشعار نظام + إشعار داخلي + نافذة منبثقة. شاشة الدردشة تحدّث نفسها بمؤقت 4 ثوانٍ + SyncActivityBus.
2. **دردشة 1:1**: محلية بالكامل (قرار سابق مقصود) — لا تُسجَّل لها عمليات مزامنة.

---

## 10. نظام المزامنة بالتفصيل (المسار الفعلي المتتبَّع)

### 10.1 ماذا يُزامَن؟
- **يُزامَن:** account, tx (+أسطر الفاتورة داخل الحمولة), item, itemCategory, stockMove, voucher, user (أدوار/صلاحيات), currency, setting (المنظمة), category, conversation, message (دردشة المجموعة).
- **لا يُزامَن:** الإشعارات، دردشة 1:1 ومرفقاتها، إعدادات الجهاز الشخصية، صور المرفقات المالية (يُزامَن المسار فقط — انظر الملاحظات).

### 10.2 كيف تنتقل البيانات؟
```
حفظ محلي (معاملة SQLite)
  └─ SyncRecorder: صف operations + صف sync_queue لكل هدف (lan / cloud)
       └─ onOperationRecorded → SyncEngine.notifyNewOperation (debounce 80ms)
            └─ processQueue: لكل transport → pickPending(20) → push
                 ├─ LAN: POST http://<peer>:43053/ops  (Bearer auth_secret)
                 └─ Cloud: PUT https://<rtdb>/workspaces/<ws>/ops/<opId>.json
الاستقبال:
  ├─ LAN: الخادم يتحقق (Bearer + is_paired + غير محظور/مطرود + حجم ≤8MB + workspace مطابق)
  │        → ConflictResolver.decide → applyRemoteOperation → onChatMessage/notify
  └─ Cloud: pull دوري 45s + مستمع SSE (لحظي) → نفس apply → إشعار الدردشة
```

### 10.3 آلية الطابور (Queue)
- sync_queue: صف لكل (عملية × هدف) بحالة pending→syncing→synced/failed. UNIQUE يمنع الازدواج، CASCADE مع operations.
- الهدفان يُحدَّدان وقت التسجيل: cloud إن كان cloudBackendUrl مضبوطاً وcloudAutoSync≠0؛ lan إن كان lanSyncEnabled=1 **أو** الجهاز داخل مجموعة (احتياط للاقترانات القديمة).
- backfill عند الإقلاع: أي عملية محلية بلا صف lan تُدرج، وصفوف lan «synced» التي لم تصل كل الأجهزة (عدّ op_deliveries < عدد الأقران) تُعاد pending.

### 10.4 إعادة المحاولة
- فشل الدفع → markFailed مع backoff متصاعد يبدأ 5 ثوانٍ ويثبت عند **سقف دقيقتين للأبد** (لا استسلام نهائي).
- مؤقت processQueue كل 8 ثوانٍ يلتقط ما حان next_try_at.
- مهلات صارمة لكل خطوة (push 20s، قراءة الطابور 10s) حتى لا يعلق الطابور كله بصف واحد.

### 10.5 Offline/Online
- **PresenceService**: يندّي `/presence` لكل قرين كل 3 ثوانٍ (مهلة 2s). الجهاز الغائب **يُتخطى بلا محاولة فاشلة** (`awaiting-offline-peers` — تبقى العملية pending بلا ضجيج).
- عند عودة قرين (onPeerOnline) → processQueue فوراً → يستلم كل المتراكم.
- السحابة: العمليات تُخزَّن في RTDB فتصل الأجهزة غير المتواجدة على نفس الشبكة لاحقاً (pull بمؤشر lastCloudTs + تداخل ثانيتين للمتأخرات).

### 10.6 اكتشاف الأجهزة
- لا يوجد mDNS/بث اكتشاف تلقائي: الأقران يُعرفون **بالاقتران** (QR محلي يحمل IP+port+token، أو دعوة سحابية) وتُخزَّن عناوينهم في devices وتتحدث مع كل طلب وارد (IP الفعلي للطلب) وعبر roster.
- roster (GET /roster كل 10 ثوانٍ + عند كل إشعار قرين): يصالح قائمة الأجهزة والأدوار والملكية، ويلتقط أسرار الأقران الناقصة (ليتحقق الأعضاء من بعضهم بغياب المدير).

### 10.7 منع تكرار العمليات (idempotency) — 4 طبقات
1. `operations.id` (UUID) PK: الوارد المكرر → `ConflictAlgorithm.ignore` + قرار `duplicate-id`.
2. `op_deliveries` PK(op,device): لا يُعاد الإرسال لجهاز استلم.
3. سحب السحابة يفحص وجود op.id قبل التطبيق.
4. المعرّفات العالمية Snowflake تمنع تصادم كيانين مختلفين بنفس id.

### 10.8 التعديل والحذف والتعارض
- التعديل: version تصاعدي لكل كيان (MAX+1). الوارد بنسخة أعلى يُطبَّق؛ الأدنى يُتجاهل؛ **التعادل يُحسم حتمياً**: timestamp الأحدث ثم deviceId الأصغر أبجدياً (نفس النتيجة على كل الأجهزة). التعارض الحقيقي يُسجَّل إشعار «تعارض في المزامنة» وتُخزَّن العملية دون تطبيق.
- الحذف: ناعم (`deleted_at`) + **مرآة سلة** على كل جهاز (بحارس `__sync_entity` ضد التكرار) — الاسترجاع من أي جهاز يزيل صف السلة عند الجميع.
- update لكيان غير موجود محلياً: تُكمَّل الأعمدة الإلزامية بقيم افتراضية آمنة بدل كسر NOT NULL وتعليق الطابور.

---

## 11. النسخ الاحتياطي — ثلاثة أنظمة منفصلة فعلياً

1. **ملف محلي JSON** (`exportAll`): كل الجداول + الصور والشعار base64 (يرفض إنشاء نسخة ناقصة إذا فُقدت صورة). الاستيراد: **حذف كل الجداول ثم استيراد** داخل معاملة، مع rollback للملفات المُنشأة عند الفشل.
2. **Google Drive**: نفس الحمولة تُرفع عبر Drive API (drive.file + appdata) بحساب Google.
3. **نسخة سحابية كاملة** (cloud_sync.dart): JSON واحد على RTDB بكود، مع حارس «النسخة البعيدة أحدث».

**قيود المجموعة (مُتحقق منها في الكود):** استعادة داخل المجموعة = مدير فقط؛ member محظور تماماً؛ النسخة تُرفض إن لم تطابق `group_fingerprint`؛ تصدير محلي للعضو بلا فحص صلاحية (localOnly) لكن الاستعادة محظورة.

---

## 12. الإشعارات والعمليات الخلفية

- **داخلية:** جدول notifications + شارة غير المقروء + نوافذ منبثقة قابلة للنقر تنقل للسجل المقصود (أو نافذة توضيحية إن لم يكن له سجل) + تحية صباح/مساء موقوتة مرة لكل فترة.
- **خارجية (نظام):** قناة أندرويد خاصة عبر MethodChannel (صوت مختلف عن إشعار المزامنة) — بلا مكتبة flutter_local_notifications.
- **مصادر الإشعار:** تسليم عملية مهمة ({tx, stockMove, voucher, account, item} فقط — بخنق 20 ثانية) + «اكتملت المزامنة مع فلان» + اتصال جهاز + رسالة دردشة (LAN + سحابة) + تغييرات المدير على العضو (اسم/دور).
- **الخلفية:** KeepAliveService (foreground service + wake lock + استثناء بطارية + إقلاع تلقائي BootReceiver) — المؤقتات: طابور 8s، حضور 3s، roster 10s، سحب سحابي 45s + SSE لحظي، صيانة 6 ساعات (طرد خاملين/فحص طردنا).

---

## 13. الصلاحيات والمصادقة والأمان

- **أدوار:** admin (مدير)، agent (وكيل — يعمل كمدير في غيابه)، accountant، dataentry، viewer. 8 صلاحيات ذرية (kPerms): add/edit/delete_tx، view_reports، export، manage_backup، manage_users، approve_vouchers.
- **الإنفاذ:** في المستودع (`_ensureCan` قبل كل كتابة — الفشل يرفض ولا يمنح صمتاً) + في خادم LAN (viewer المقترن لا يستطيع كتابة مالية عبر HTTP) + في الواجهة (إخفاء ما لا صلاحية له).
- **اقتران LAN:** token مؤقت في QR → تبادل auth_secret → كل طلب لاحق Bearer. الأسرار لا تُرفع للسحابة (تُفرَّغ في اللقطات)، وأسرار المحظورين لا تُوزَّع.
- **قفل التطبيق:** بصمة/قفل نظام (local_auth) + كلمات مرور مستخدمين SHA-256 بملح ثابت.
- **الفرمتة (wipeGroupData):** مدير فقط + قفل نظام إلزامي + مهلة شهر، تحفظ الإعدادات والصلاحيات وتُزامن الحذف للجميع.
- الطرد: HTTP 410 من المضيف → العضو يمسح بياناته ويعود مستقلاً تلقائياً.

---

## 14. محلي مقابل شبكي

| يعمل محلياً 100% | يحتاج LAN | يحتاج إنترنت |
|---|---|---|
| كل CRUD والتقارير والسندات وPDF والسلة والنشاط والدردشة 1:1 والنسخة المحلية والقفل | مزامنة فورية بين الأجهزة، حضور، اقتران QR، roster | مزامنة سحابية RTDB، الدعوة السحابية، Google Drive، التحديث الذاتي، واتساب |

مبدأ **Offline-first** فعلي: الحفظ لا ينتظر الشبكة أبداً؛ الطابور يلحق لاحقاً.

---

## 15. الخدمات الخارجية

1. **Firebase RTDB** (`nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app`، خطة Spark) عبر REST خام: `/workspaces/<ws>/ops`, `/joinSnapshot`, `/invites/<TOKEN>`, `/devices` + SSE.
2. **Google Sign-In + Drive API** للنسخ.
3. **GitHub Releases** للتحديث الذاتي (version.json + APK/EXE).
4. **واتساب** عبر url_launcher/قناة أندرويد لإرسال كشوفات وإيصالات.

---

## 16. الوضع الحالي للمشروع (كما هو فعلياً)

- المستودع على GitHub، HEAD = 572d507 (3.31.1+54)، CI ثلاثي (تحقق/APK/EXE) كان قيد التنفيذ آخر فحص. الإصدارات تُنشر على وسم latest مع version.json فيلتقطها المحدّث داخل التطبيق.
- **213+ اختباراً** في 25 ملفاً تغطي: ذرية الحفظ، حالات الطابور، أمن LAN (رفض غير الموثوق/المحظور/viewer)، الاقتران واللقطة، الانضمام السحابي بالمسح الكامل، حسم التعارض، السلة، الترقيم، الصمت الجديد للدردشة. `flutter analyze`: 83 ملاحظة info فقط (أسلوبية)، صفر تحذيرات.
- الميزات الشغالة عملياً وفق التتبع: المزامنة الفورية LAN مع حضور وتخطي الغائبين، السحابة push+pull+SSE، الانضمام السحابي بمسح كامل ولقطة، الأدوار والوكيل ونقل الملكية والطرد، الدردشة الجماعية بمرفقات، POS كامل، السندات PDF، التحديث الذاتي one-click، اليقظة الخلفية.
- آخر إصلاح جوهري (3.31.0): مصالحة roster كانت **تنسخ workspaceMode من جهاز عضو فتقلب المدير إلى عضو زوراً** — الآن يُشتق من is_owner فقط، وإنشاء الدعوة يصلح الوضع الخاطئ ذاتياً.
- سلوك الدردشة الحالي: إشعارات كاملة (صوت/نظام/داخلي/منبثقة) من LAN والسحابة معاً، مع بقائها خارج شاشة عمليات المزامنة وعداداتها.

---

## 17. الملاحظات والمشاكل المحتملة (بلا إصلاح — للعلم فقط)

### أ. أمان
1. **قواعد RTDB عامة عملياً** — `cloud_firebase_transport.dart` يتراجع إلى طلب بلا auth عند 401/403، والاعتماد الفعلي على سرية مسار workspace. أي من يعرف الرابط + ws يقرأ/يكتب دفاتر المجموعة. (خطة Spark بلا قواعد مخصصة مذكورة في الكود).
2. **LAN بلا تشفير** — HTTP خام؛ Bearer secret يمر نصاً على الشبكة المحلية (مقبول لشبكة محل، لكنه يُذكر).
3. **ملح كلمات المرور ثابت** (`nexora::` في security.dart:66) — هاش متطابق لكلمتين متطابقتين عبر الأجهزة؛ بلا bcrypt/تكرار.
4. **PAT الخاص بـ GitHub ظهر في المحادثة سابقاً ولم يُؤكد إبطاله** — يجب إبطاله.
5. توكن الدعوة السحابية صالح 24h وحذفه بعد الاستخدام «أفضل جهد» (`_delete` يبتلع الأخطاء — cloud_join.dart:111).

### ب. تصميم/تناقضات
6. **قيم workspaceMode ثلاث بدل اثنتين**: 'host' و'managed' تُستخدمان لمعنى واحد (repository.dart:236 يكتب 'managed'، lan_http_transport.dart:341 يكتب 'host'، والفحوصات تُقارن أحياناً بأحدهما فقط — مثال backup_screen:488 يفحص `!= 'member'` فيسلم، لكن repository.dart:2476 يفحص `== 'host'` ولن يلتقط 'managed').
7. **حمولة العمليات تتضخم بلا تقليم**: جدول operations يحتفظ بكل عملية للأبد، ومرفق دردشة 6MB يبقى base64 داخل payload محلياً وفي RTDB إلى الأبد — نمو غير محدود للقاعدة المحلية ولاستهلاك RTDB (خطة Spark 1GB).
8. **صور المرفقات المالية لا تُنقل**: عمود image/attachment في transactions يزامن **المسار المحلي فقط** — الجهاز الآخر يستقبل مساراً لا وجود له عنده (بعكس مرفقات الدردشة المضمنة base64).
9. حد LAN payload 8MB مقابل مرفق 6MB قبل الترميز: base64 يضخم ~33% + غلاف JSON → مرفق 6MB فعلي ≈ 8MB مرمّزاً وقد يلامس الرفض عند الحد.
10. **نظاما نسخ سحابي متوازيان** (cloud_sync.dart «نسخة كاملة بكود» + المزامنة التشغيلية ops) بلا علاقة بينهما — قد يستعيد المستخدم نسخة كاملة قديمة فوق دفاتر متزامنة أحدث (يوجد حارس remoteIsNewer للرفع فقط، لا للسحب).
11. مؤشر السحب السحابي lastCloudTs بتداخل ثانيتين يعتمد على **توقيت أجهزة المرسلين** (timestamp نصي ISO يولده كل جهاز) — انحراف ساعة جهاز > ثانيتين للخلف قد يجعل عملياته تُقفز عند الآخرين حتى backfill/إعادة تشغيل.
12. الترقيم التسلسلي للفواتير عدّاد محلي لكل جهاز (settings) + MAX(reference) — جهازان يصدران فاتورة بنفس الرقم في نفس اللحظة قبل تزامنهما (الرقم للعرض فقط، لكن التكرار وارد على الإيصالات).

### ج. تنفيذية صغيرة
13. `_lineMaps` يُستدعى داخل معاملة الحفظ بعد الإدراج لبناء الحمولة — سليم، لكن أسطر الفاتورة تُحذف وتُعاد كتابتها كاملة عند كل تعديل (نسخ versions أكبر).
14. إشعار «اكتملت المزامنة» يفحص طابور lan فقط (sync_engine.dart:180) — قد يظهر رغم بقاء صفوف cloud معلقة.
15. سجل الأنشطة والسلة محليان في اللقطة لكن ليسا كيانات مزامنة تشغيلية (activity يصل عبر اللقطات فقط) — سجلات النشاط تتباعد بين الأجهزة بعد الانضمام.
16. `google_auth.id_token` يخزن التوكن نصاً في SQLite بلا تشفير.
17. عمود `synced` في operations يُحدَّث عند نجاح **السحابة** فقط؛ دلالته ملتبسة مع مسار LAN (LAN يعتمد op_deliveries).
18. أسماء بعض الثوابت تختلف عن السلوك: SyncTarget.lanBroadcast يُخزَّن نصاً 'lan' في الطابور — متسق داخلياً لكن يربك عند فحص القاعدة يدوياً.

*(لا شيء مما سبق أُصلح في هذه المرحلة — بحسب طلبك.)*
