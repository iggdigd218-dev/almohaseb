# ============ Flutter ============
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ============ الإضافات المستدعاة عبر الانعكاس ============
# هذه الأصناف تُسجَّل ديناميكيًا، وحذفها يسبب انهيارًا وقت التشغيل
-keep class co.quis.flutter_contacts.** { *; }
-keep class dev.flutter.plugins.** { *; }
-keep class com.crazecoder.openfile.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }

# ============ البصمة / local_auth ============
-keep class androidx.biometric.** { *; }
-keep class androidx.fragment.app.** { *; }
-keep class io.flutter.plugins.localauth.** { *; }

# ============ جسور الكود الأصلي ============
-keep class com.tadween.tadween_app.** { *; }
-keep class android.accounts.** { *; }

# ============ sqflite ============
-keep class com.tekartik.sqflite.** { *; }

# ============ تحذيرات غير مؤثرة ============
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.android.play.core.**

# الحفاظ على أسماء الأسطر لتتبّع الأعطال
-keepattributes SourceFile,LineNumberTable,*Annotation*,Signature

# ============ (2026-11-22) قواعد تفعيل R8 ============
# كان minifyEnabled=false فبقيت الحزم 25-28MB وتجاوزت حدّ 20MB.
# هذه القواعد تحفظ ما يُستدعى بالانعكاس فقط.
-keep class com.tekartik.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }
-keep class com.baseflow.** { *; }
-keep class android.print.** { *; }
-dontwarn org.jetbrains.annotations.**
-dontwarn kotlin.**
-dontwarn kotlinx.**
-dontwarn com.google.android.play.core.**
-dontwarn androidx.camera.**
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
