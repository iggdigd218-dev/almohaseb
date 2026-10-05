// QA — ختم التطبيق (العلامة المائية) على مخرجات PDF (دفعة 65-ب).
//
// العقد: الحساب المقيد **لا يُحجب** عن التصدير — الملف يُنتَج كاملاً
// وعليه ختم مائي. هذه الاختبارات تثبت أن الختم محتوى رسم **فعلي** في
// الصفحة لا مجرد وسيط مُهمَل: المستند المختوم أطول من الساذج دائماً.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/ui/voucher_doc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('الختم يضيف محتوى رسم فعلياً لصفحة PDF', () async {
    await initializeDateFormatting('ar');
    final now = DateTime.now();
    final v = Voucher(
      id: 1,
      number: 'V-1',
      kind: VoucherKind.receipt,
      accountId: null,
      txId: null,
      amount: 100,
      currency: 'YER',
      status: 'approved',
      date: now,
      createdAt: now,
      updatedAt: now,
    );
    const org = OrgInfo(
      name: 'متجر تجريبي',
      phone: '',
      address: '',
      managerName: '',
      footer: 'شكراً لزيارتكم',
      logoPath: '',
    );

    Future<int> build(bool stamp) async => (await buildVoucherPdf(
          v: v,
          account: null,
          currency: kDefaultCurrencies.first,
          org: org,
          items: const [],
          stamp: stamp,
        ))
            .length;

    final plain = await build(false);
    final stamped = await build(true);
    expect(plain, greaterThan(0), reason: 'السند الساذج يُنتَج');
    expect(stamped, greaterThan(plain),
        reason: 'المختوم أطول — دليل على رسم الختم لا تجاهله');
  });

  test('السند يُنتَج بلا ختم عندما لا يلزم', () async {
    await initializeDateFormatting('ar');
    final now = DateTime.now();
    final v = Voucher(
      id: 2,
      number: 'V-2',
      kind: VoucherKind.payment,
      accountId: null,
      txId: null,
      amount: 50,
      currency: 'YER',
      status: 'approved',
      date: now,
      createdAt: now,
      updatedAt: now,
    );
    const org = OrgInfo(
      name: 'متجر تجريبي',
      phone: '',
      address: '',
      managerName: '',
      footer: 'شكراً',
      logoPath: '',
    );
    final bytes = await buildVoucherPdf(
      v: v,
      account: null,
      currency: kDefaultCurrencies.first,
      org: org,
      stamp: false,
    );
    expect(bytes, isNotEmpty);
  });
}
