// اختبارات كتابة المبلغ بالحروف.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/words.dart' as words;

void main() {
  test('المبلغ كتابة', () {
    expect(words.amountInWords(2000, 'local'), 'ألفان ريال فقط لا غير');
    expect(words.amountInWords(5000, 'local'), 'خمسة آلاف ريال فقط لا غير');
    expect(words.amountInWords(3500, 'dollar'),
        'ثلاثة آلاف و خمسمائة دولار فقط لا غير');
    expect(words.amountInWords(1, 'saudi'), 'واحد ريال سعودي فقط لا غير');
    expect(words.amountInWords(0, 'local'), 'صفر ريال فقط لا غير');
    expect(words.amountInWords(21, 'local'), 'واحد و عشرون ريال فقط لا غير');
  });
}
