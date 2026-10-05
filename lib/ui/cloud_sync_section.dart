// حوارات الدعوة/الانضمام عبر السحابة (المعمارية الصامتة — صفر إعداد يدوي).
//
// - المدير: ينشئ «دعوة سحابية» (QR + رمز) لربط أعضاء بعيدين — الرابط
//   الرسمي مضمّن برمجياً، لا حقول روابط ولا رموز يدوية في أي شاشة.
// - الجهاز المستقل: ينضم لمجموعة عبر مسح QR أو رمز دعوة — تُحذف كل
//   بياناته المحلية وتُستبدل بنسخة المجموعة ثم يتزامن.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart';
import 'widgets.dart';

/// حوار «دعوة سحابية» — للمدير: يرفع لقطة المجموعة ويعرض QR + رمز الدعوة.
Future<void> showCloudInviteDialog(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(repoProvider);
  // (3.70.0 — بوابة الأمان) نقطة خنق واحدة لكل مداخل إنشاء الدعوات:
  // لا رمز QR ولا PIN إلا بحساب Google موثق في جدول google_auth.
  try {
    final db = await repo.database;
    final r = await db.query('google_auth', where: 'id = 1', limit: 1);
    final linked =
        r.isNotEmpty && '${r.first['google_id'] ?? ''}'.trim().isNotEmpty;
    if (!linked) {
      if (context.mounted) {
        showSnack(
            context,
            'بوابة الأمان: وثّق حساب Google أولاً (الإعدادات ← حساب المؤسسة) '
            'قبل إنشاء رموز الدعوة',
            error: true);
      }
      return;
    }
  } catch (_) {
    // تعذّر الفحص محلياً (قاعدة مقفلة): لا نمنع الإدارة — تكمل الدعوة
    // بفحوصها السحابية القائمة (الملكية + الاشتراك).
  }
  if (!context.mounted) return;
  // (دفعة 65 — كسر حلقة التعليق) ثلاث ضمانات كانت مفقودة فكانت الشاشة
  // تتجمّد إلى الأبد:
  //   ١) مهلة قصوى على العملية نفسها (كان رفع اللقطة بلا مهلة فيصل إلى
  //      دقيقتين مع مسار إعادة محاولة 401).
  //   ٢) الحوار **قابل للإلغاء** بيد المستخدم.
  //   ٣) إغلاق حتمي في `finally`: نجاح، فشل، مهلة، أو مغادرة الشاشة.
  var cancelled = false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      content: const Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(
            child: Text('جارٍ رفع نسخة المجموعة إلى السحابة وإنشاء الدعوة...',
                style: TextStyle(height: 1.5)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            Navigator.of(dialogCtx).pop();
          },
          child: const Text('إلغاء'),
        ),
      ],
    ),
  );
  CloudInviteInfo? invite;
  String? error;
  try {
    // (دفعة 65 — تصحيح انحدار) إنشاء الدعوة يرفع لقطة قاعدة البيانات
    // كاملة: مهلة 15 ثانية كانت تجهضه قبل كتابة الدعوة في كل مؤسسة
    // بحجم واقعي أو اتصال هاتفي، فلا يجد العضو المساحة أبداً.
    invite = await CloudJoin.createInvite(repo).timeout(kCloudInviteTimeout);
  } on TimeoutException {
    error = 'انتهت مهلة إنشاء الدعوة '
        '(${kCloudInviteTimeout.inSeconds ~/ 60} دقائق) — '
        'تحقّق من شبكتك ثم أعد المحاولة.';
  } catch (e) {
    error = e is CloudJoinException ? e.message : '$e';
  } finally {
    // إغلاق حتمي — لا يُترك الحوار مفتوحاً تحت أي ظرف.
    if (!cancelled && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
  if (!context.mounted || cancelled) return;
  if (invite == null) {
    Sfx.error();
    showSnack(context, '❌ تعذّر إنشاء الدعوة: ${error ?? 'خطأ غير معروف'}',
        error: true);
    return;
  }
  Sfx.pair();
  final inv = invite;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _CloudInviteDialog(invite: inv),
  );
}

/// حوار دعوة الاقتران (دفعة 51): QR + رمز PIN كبير من 6 أرقام
/// + عدّاد تنازلي لصلاحية 15 دقيقة.
class _CloudInviteDialog extends StatefulWidget {
  const _CloudInviteDialog({required this.invite});
  final CloudInviteInfo invite;

  @override
  State<_CloudInviteDialog> createState() => _CloudInviteDialogState();
}

class _CloudInviteDialogState extends State<_CloudInviteDialog> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final left = inv.expiresAt.difference(DateTime.now());
    final expired = left.isNegative;
    final mm = left.inMinutes.clamp(0, 99).toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('إضافة جهاز جديد'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: inv.qrContent,
                  size: 180,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (inv.pin.isNotEmpty) ...[
              Center(
                child: Column(
                  children: [
                    const Text('أو أدخل هذا الرمز على الجهاز الجديد:',
                        style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(
                        '${inv.pin.substring(0, 3)} ${inv.pin.substring(3)}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: (expired ? Colors.red : Colors.orange)
                      .withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  expired
                      ? '⛔ انتهت صلاحية الدعوة — أنشئ دعوة جديدة'
                      : '⏱ تنتهي الدعوة خلال $mm:$ss',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: expired ? Colors.red : Colors.orange.shade800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'على الجهاز الجديد: «الانضمام إلى مجموعة» ← تسمية الجهاز ← '
              'مسح الرمز أو إدخال الأرقام. سيصلك هنا طلب موافقة قبل تفعيله.',
              style: TextStyle(fontSize: 11.5, height: 1.6),
            ),
            const SizedBox(height: 8),
            _copyRow(context, 'الرابط', inv.backendUrl),
            _copyRow(context, 'رمز الدعوة', inv.token),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}

Widget _copyRow(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(
                value,
                maxLines: 2,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          IconButton(
            iconSize: 16,
            tooltip: 'نسخ',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Sfx.click();
              showSnack(context, 'تم النسخ ✅');
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
    );

/// حوار «الانضمام عبر السحابة» — للجهاز الجديد: رابط + رمز دعوة (أو من QR).
Future<void> showCloudJoinDialog(
  BuildContext context,
  WidgetRef ref, {
  String? prefillUrl,
  String? prefillToken,
  String? prefillWs,
  String? prefillCode,
}) async {
  final urlCtrl = TextEditingController(text: prefillUrl ?? '');
  final tokCtrl = TextEditingController(text: prefillToken ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('الانضمام إلى مجموعة عبر السحابة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'أدخل رابط قاعدة البيانات ورمز الدعوة اللذين أنشأهما المدير '
            'من إعداداته (المزامنة السحابية ← دعوة انضمام).',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: urlCtrl,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'رابط قاعدة البيانات (https://...)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: tokCtrl,
            textDirection: TextDirection.ltr,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'رمز الدعوة',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('متابعة'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await performCloudJoin(
    context,
    ProviderScope.containerOf(context, listen: false),
    backendUrl: urlCtrl.text,
    token: tokCtrl.text,
    workspaceId: prefillWs ?? 'default',
    cloudCode: prefillCode ?? '',
  );
}

/// ينفّذ الانضمام السحابي الكامل: تأكيد مسح البيانات ← جلب اللقطة ←
/// استبدال البيانات ← إعادة تشغيل محرك المزامنة كعضو.
Future<void> performCloudJoin(
  BuildContext context,
  ProviderContainer container, {
  required String backendUrl,
  required String token,
  String workspaceId = 'default',
  String cloudCode = '',
}) async {
  // تأكيد صريح: الانضمام يحذف كل البيانات المحلية أولاً.
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تأكيد الانضمام إلى المجموعة'),
      content: const Text(
        'سيتم حذف جميع البيانات والسجلات المحلية في هذا الجهاز بالكامل، '
        'واستبدالها بنسخة كاملة من بيانات المجموعة من السحابة، '
        'ثم يتزامن الجهاز تلقائياً مع بقية الأجهزة.\n\n'
        'هذا الإجراء لا يمكن التراجع عنه.\n\nهل تريد المتابعة؟',
        style: TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('انضمام ومسح البيانات'),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(
            child: Text(
                'جارٍ تنزيل نسخة المجموعة من السحابة واستبدال البيانات...',
                style: TextStyle(height: 1.5)),
          ),
        ],
      ),
    ),
  );

  String? failure;
  try {
    final repo = container.read(repoProvider);
    // (دفعة 65) مهلة كلية على العملية المركّبة (تنزيل + استبدال + إقلاع
    // المحرك) — بلاها كان الحوار غير القابل للإلغاء يبقى مفتوحاً إلى
    // الأبد عند أي تعليق شبكي. المهلة أوسع من kCloudOpTimeout لأن
    // العملية تشمل تنزيل لقطة كاملة.
    await CloudJoin.join(
      repo,
      backendUrl: backendUrl,
      token: token,
      workspaceId: workspaceId,
      cloudCode: cloudCode,
    ).timeout(kCloudOpTimeout * 4);
    // إعادة تشغيل محرك المزامنة بالحالة الجديدة (عضو + سحابة مفعّلة).
    final engine = container.read(syncEngineProvider);
    engine.stop();
    await engine.start();
  } on TimeoutException catch (_) {
    failure = 'انتهت مهلة تنزيل نسخة المجموعة '
        '(${(kCloudOpTimeout * 4).inSeconds} ثانية) — تحقّق من الشبكة '
        'ثم أعد المحاولة. لم يُعتمد أي تغيير على بياناتك.';
  } catch (e) {
    failure = e is CloudJoinException ? e.message : '$e';
  } finally {
    // (دفعة 65) إغلاق حتمي: النسخة السابقة كانت تتحقق من `context.mounted`
    // قبل الإغلاق، فإن غاب السياق بقي الحوار مفتوحاً بلا أمل.
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  if (!context.mounted) return;

  if (failure != null) {
    Sfx.error();
    showSnack(context, '❌ فشل الانضمام: $failure', error: true);
    return;
  }
  Sfx.pair();
  container.read(refreshProvider.notifier).state++;
  showSnack(
    context,
    '✅ تم الانضمام إلى المجموعة عبر السحابة: حُذفت البيانات المحلية '
    'واستُبدلت بنسخة المجموعة. سيعين لك المدير الصلاحيات.',
  );
  await Future.delayed(const Duration(milliseconds: 300));
  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
}
