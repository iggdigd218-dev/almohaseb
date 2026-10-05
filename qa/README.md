# إعادة تشغيل فحوص المرحلة 4

## البيئة
Flutter **3.47.2** / Dart **3.13.2**، Linux x64. قواعد الاختبار مؤقتة ومعزولة. لم يُستخدم حساب Google حقيقي، أو Firebase إنتاجي، أو بيانات عميل.

```bash
bash qa/run_checks.sh
```

لا تتجاوز الاختبارات الفاشلة: ملف `qa_release_blockers_test.dart` ضمن الاختبارات الافتراضية عمدًا.

| الملف | نوع الدليل |
|---|---|
| `qa_save_flow_test.dart` | Widgets حقيقية، وحدّ خدمة متحكّم فيه للتأخير والرفض والضغط المتكرر |
| `qa_end_to_end_test.dart` | HomeShell وTxForm الحقيقيان + Repo + SQLite + تحديث القائمة والرصيد + إعادة فتح القاعدة |
| `qa_data_sync_test.dart` | SQLite فعلية، حالات الصف والمحاولات وrollback والأرصدة |
| `qa_lan_test.dart` | HTTP loopback فعلي بين قاعدتين، ببيانات اعتماد مصطنعة. يُعطّل HttpOverrides الوهمي في هذا الاختبار فقط |
| `qa_screens_test.dart` | 16 شاشة × عرضَي 360/1000، بخط Tajawal وقاعدة SQLite. اختبار ظهور وتخطيط؛ ليس اختبار كل زر وكل نظام تشغيل |
| `qa_lifecycle_test.dart` | إلغاء المؤقتات وفصل callback عند إيقاف المحرك |

لتوليد جدول النتائج مجددًا بعد تشغيل الاختبارات بصيغة JSON:

```bash
flutter test --no-pub --concurrency=1 --coverage --reporter json > qa/evidence/tests-final.jsonl
python3 qa/make_test_summary.py
```

## المعاينة الحقيقية

ليست تحويلًا للتطبيق إلى Web. هي Linux runner مؤقت يستخدم نفس `lib/` و`assets/`، مع Xvfb وnoVNC. الملف القديم `live_preview.html` محاكاة مستقلة ولا يدخل في أدلة QA.

```bash
# حزم Debian اللازمة للمعاينة:
# clang cmake ninja-build pkg-config libgtk-3-dev xvfb x11vnc novnc websockify
bash qa/prepare_preview.sh
```

شغّل الخدمات التالية كعمليات طويلة العمر:

1. `Xvfb :99 -screen 0 1100x820x24 -nolisten tcp -ac`
2. `DISPLAY=:99 XDG_DATA_HOME="$HOME/.cache/qa-app-data" LIBGL_ALWAYS_SOFTWARE=1 "$HOME/.cache/nexora_qa_runtime/build/linux/x64/debug/bundle/nexora_app"`
3. `x11vnc -display :99 -localhost -rfbport 5901 -forever -shared -nopw -noxdamage`
4. `websockify --web "$PWD/qa/preview" 0.0.0.0:6080 127.0.0.1:5901`

واجهة 6080 مخصصة لجلسة QA معزولة، وليست خدمة إنتاج. لا تعرّضها علنًا ولا تضع فيها بيانات حساسة. يمكن تغيير مقاس النافذة بعد ظهورها باستخدام xdotool.

بيانات المعاينة في `.cache/qa-app-data/` مستقلة عن التطبيق المثبت. الحزم والأدوات ومخرجات البناء قابلة لإعادة الإنشاء، وليست ضمن حزمة المصدر.

## الحدود المهمة

- لا Android SDK/محاكي، ولا Windows host: بناء واختبارات الأجهزة الأصلية **BLOCKED** محليًا.
- لا إثبات لاتصال Firebase/Google/Drive أو كاميرا/بصمة/واتساب/طباعة فعلية. HTTP المحلي ليس Firebase.
- التحليل الأصلي للمشروع لا يفعّل مجموعة `flutter_lints`. نتيجة التدقيق الإضافي في runner منفصلة، ولا تُخفى نتيجته غير الصفرية.
- مهلة UI لا تلغي SQLite Future. يبقى قفل الحفظ حتى تحسم الكتابة، مع تنبيه عند التأخر. القتل القسري أثناء commit على Android لم يُختبر.
- القياسات المتاحة Linux debug وليست قياسات أداء Android Release أو اختبار تسرب طويل المدى.
