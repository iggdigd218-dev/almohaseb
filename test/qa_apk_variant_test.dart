import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/update_service.dart';

/// تغطية اختيار حزمة APK: المعالج أولاً، والشاملة بديلاً آمناً.
void main() {
  const downloads = {
    'android': 'https://ex.test/nexora-universal.apk',
    'androidVariants': {
      'arm64': 'https://ex.test/nexora-arm64.apk',
      'armv7': 'https://ex.test/nexora-armv7.apk',
      'x64': 'https://ex.test/nexora-x64.apk',
    },
    'windows': 'https://ex.test/NexoraSetup.exe',
  };

  test('APK-01: arm64 يأخذ حزمة arm64', () {
    expect(pickAndroidApkUrl(downloads, 'arm64'),
        'https://ex.test/nexora-arm64.apk');
  });

  test('APK-02: armv7 يأخذ حزمة armv7', () {
    expect(pickAndroidApkUrl(downloads, 'armv7'),
        'https://ex.test/nexora-armv7.apk');
  });

  test('APK-03: معالج مجهول ⇒ الشاملة', () {
    expect(pickAndroidApkUrl(downloads, null),
        'https://ex.test/nexora-universal.apk');
  });

  test('APK-04: معالج بلا حزمة مطابقة ⇒ الشاملة', () {
    expect(pickAndroidApkUrl(downloads, 'mips'),
        'https://ex.test/nexora-universal.apk');
  });

  test('APK-05: بيان قديم بلا androidVariants ⇒ الشاملة', () {
    expect(pickAndroidApkUrl({'android': 'https://ex.test/u.apk'}, 'arm64'),
        'https://ex.test/u.apk');
  });

  test('APK-06: رابط غير https يُرفض', () {
    expect(pickAndroidApkUrl({'android': 'http://ex.test/u.apk'}, 'arm64'),
        isNull);
  });

  test('APK-07: downloads فارغ ⇒ null (لا انهيار)', () {
    expect(pickAndroidApkUrl(null, 'arm64'), isNull);
    expect(pickAndroidApkUrl('not-a-map', 'arm64'), isNull);
  });
}
