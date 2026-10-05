package com.nexora.eradata

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * FlutterFragmentActivity وليس FlutterActivity: مكتبة البصمة (local_auth)
 * تتطلّب FragmentActivity لعرض نافذة المصادقة، وبدونها لا تعمل البصمة.
 */
class MainActivity : FlutterFragmentActivity() {
    private val waChannel = "nexora/whatsapp"
    private val updateChannel = "nexora/updates"
    private val sfxChannel = "nexora/sfx"

    /** أوامر الزر العائم القادمة من بلاطة الإعدادات السريعة (الستارة). */
    private val overlayChannel = "nexora/overlay"
    private val waPackages = listOf("com.whatsapp", "com.whatsapp.w4b")
    private var mediaPlayer: android.media.MediaPlayer? = null

    /** قناة فلاتر النشطة — تُستخدم لتبليغ فلاتر بأمر الستارة فوراً. */
    private var overlayMethod: MethodChannel? = null

    /** أمر ستارة معلّق لم يستلمه فلاتر بعد (إقلاع بارد). */
    private var pendingTileAction: Map<String, Any?>? = null

    /** آخر نقرة إشعار خارجي لم تُستهلك بعد: {entityType, entityId}. */
    private var pendingNotifyTap: Map<String, String>? = null

    /** نتيجة طلب إذن نظام معلّقة (تُستوفى في onRequestPermissionsResult). */
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQ_CODE) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    companion object {
        private const val PERMISSION_REQ_CODE = 7801

        /** نية تشغيل الزر العائم من بلاطة الإعدادات السريعة (الستارة). */
        const val ACTION_QUICK_POS = "com.nexora.eradata.QUICK_POS"
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureNotifyTap(intent)
        captureTileAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNotifyTap(intent)
        captureTileAction(intent)
    }

    /**
     * يلتقط أمر الستارة: إن كان فلاتر حيّاً نُبلّغه فوراً عبر القناة،
     * ونحفظه معلقاً في كل الأحوال ليأخذه فلاتر عند الإقلاع البارد
     * (الاستدعاء عامل آمن — `show` في فلاتر عملية عاطلة عن التكرار).
     */
    private fun captureTileAction(intent: Intent?) {
        if (intent?.action != ACTION_QUICK_POS) return
        val args = mapOf<String, Any?>(
            "permission" to intent.getBooleanExtra(
                QuickPosTileService.EXTRA_NEED_PERMISSION, false
            )
        )
        pendingTileAction = args
        try {
            overlayMethod?.invokeMethod("tile", args)
        } catch (_: Exception) { }
        // لا نُعالج النية نفسها مرتين عند استئناف النشاط.
        intent.action = null
        intent.removeExtra(QuickPosTileService.EXTRA_NEED_PERMISSION)
    }

    /** يلتقط بيانات الكيان من Intent نقرة الإشعار الخارجي (إن وُجدت). */
    private fun captureNotifyTap(intent: Intent?) {
        val type = intent?.getStringExtra("nx_entity_type") ?: return
        if (type.isEmpty()) return
        pendingNotifyTap = mapOf(
            "entityType" to type,
            "entityId" to (intent.getStringExtra("nx_entity_id") ?: ""),
        )
        // لا نلتقط النقرة نفسها مرتين عند استئناف النشاط.
        intent.removeExtra("nx_entity_type")
        intent.removeExtra("nx_entity_id")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // قناة الزر العائم: أوامر بلاطة الستارة + تسليم الأمر المعلّق عند الإقلاع.
        val overlay = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannel)
        overlay.setMethodCallHandler { call, result ->
            when (call.method) {
                // فلاتر يسأل عن أمر ستارة معلّق (إقلاع بارد).
                "takeTile" -> {
                    result.success(pendingTileAction)
                    pendingTileAction = null
                }
                else -> result.notImplemented()
            }
        }
        overlayMethod = overlay

        // قناة الأصوات المخصصة/الاهتزاز الطويل/الإشعارات الخارجية بصوت مميز.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, sfxChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // تشغيل ملف صوت من res/raw باسمه (بدون امتداد).
                    "play" -> {
                        val name = call.argument<String>("name") ?: ""
                        result.success(playRaw(name))
                    }
                    // اهتزاز بمدة محددة بالمللي ثانية (1000-2000 عند إنشاء عملية).
                    "vibrate" -> {
                        val ms = (call.argument<Int>("ms") ?: 300).coerceIn(10, 3000)
                        vibrateMs(ms.toLong())
                        result.success(true)
                    }
                    // إشعار نظام خارجي بصوت مخصص مختلف عن صوت النظام الافتراضي.
                    "notify" -> {
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        val sound = call.argument<String>("sound") ?: "nexora_alert"
                        val entityType = call.argument<String>("entityType") ?: ""
                        val entityId = call.argument<String>("entityId") ?: ""
                        result.success(
                            showNotification(title, body, sound, entityType, entityId)
                        )
                    }
                    // يسلّم نقرة الإشعار الخارجي المعلقة لفلاتر (مرة واحدة).
                    "takeNotifyTap" -> {
                        result.success(pendingNotifyTap)
                        pendingNotifyTap = null
                    }
                    // تشغيل/إيقاف خدمة اليقظة (foreground service + wake lock):
                    // تُفعّل داخل المجموعة لتستمر المزامنة والإشعارات والشاشة مطفأة.
                    "keepAlive" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        getSharedPreferences("nexora_keepalive", MODE_PRIVATE)
                            .edit().putBoolean("enabled", on).apply()
                        if (on) KeepAliveService.start(this)
                        else KeepAliveService.stop(this)
                        result.success(true)
                    }
                    // هل التطبيق معفى من تحسينات البطارية؟
                    "isBatteryExempt" -> {
                        result.success(
                            if (android.os.Build.VERSION.SDK_INT >= 23) {
                                val pm = getSystemService(POWER_SERVICE)
                                    as android.os.PowerManager
                                pm.isIgnoringBatteryOptimizations(packageName)
                            } else true
                        )
                    }
                    // نافذة النظام الرسمية لطلب الإعفاء من تحسينات البطارية —
                    // إذن نظام حقيقي وليس نافذة مصطنعة من التطبيق.
                    "requestBatteryExempt" -> {
                        result.success(
                            if (android.os.Build.VERSION.SDK_INT >= 23) {
                                launch(
                                    Intent(
                                        android.provider.Settings
                                            .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            } else true
                        )
                    }
                    // طلب إذن نظام حقيقي (نافذة أندرويد الرسمية) باسمه الكامل.
                    "requestSystemPermission" -> {
                        val perm = call.argument<String>("permission") ?: ""
                        if (perm.isEmpty()) {
                            result.success(false)
                        } else if (checkSelfPermission(perm) ==
                            PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else {
                            pendingPermissionResult = result
                            requestPermissions(arrayOf(perm), PERMISSION_REQ_CODE)
                        }
                    }
                    // هل الإذن ممنوح حالياً؟
                    "hasSystemPermission" -> {
                        val perm = call.argument<String>("permission") ?: ""
                        result.success(
                            perm.isNotEmpty() && checkSelfPermission(perm) ==
                                PackageManager.PERMISSION_GRANTED
                        )
                    }
                    // تسجيل صوتي (رسائل الدردشة): يبدأ التسجيل إلى ملف m4a.
                    "startRecording" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(startAudioRecording(path))
                    }
                    // يوقف التسجيل ويعيد true إن كان الملف صالحاً.
                    "stopRecording" -> result.success(stopAudioRecording())
                    // تشغيل ملف صوتي من مسار كامل (رسالة صوتية مستلمة).
                    "playFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(playAudioFile(path))
                    }
                    // إيقاف أي تشغيل جارٍ.
                    "stopPlayback" -> {
                        try { mediaPlayer?.stop(); mediaPlayer?.release() }
                        catch (_: Exception) {}
                        mediaPlayer = null
                        result.success(true)
                    }
                    // فتح ملف (فيديو/مستند...) بتطبيق النظام المناسب.
                    "openFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(openFileWithSystem(path))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, waChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installed" -> result.success(installedPackages())
                    "send" -> {
                        val phone = call.argument<String>("phone") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val path = call.argument<String>("path")
                        val pkg = call.argument<String>("package")
                        result.success(send(phone, text, path, pkg))
                    }
                    else -> result.notImplemented()
                }
            }

        // قناة التحديث بنقرة واحدة: تفتح شاشة تثبيت النظام لملف APK منزَّل.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // هل سمح المستخدم لهذا التطبيق بتثبيت الحزم؟ (أندرويد 8+)
                    "canInstall" -> result.success(
                        if (android.os.Build.VERSION.SDK_INT >= 26)
                            packageManager.canRequestPackageInstalls()
                        else true
                    )
                    // يفتح إعدادات «تثبيت التطبيقات غير المعروفة» لهذا التطبيق.
                    "openInstallSettings" -> {
                        result.success(
                            if (android.os.Build.VERSION.SDK_INT >= 26) {
                                launch(
                                    Intent(
                                        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            } else true
                        )
                    }
                    // يطلق شاشة تثبيت النظام لملف الـ APK المحدد.
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(installApk(path))
                    }
                    // تنزيل عبر مدير تنزيلات النظام: يستمر في الخلفية حتى لو
                    // أُغلق التطبيق، ويستأنف تلقائياً عند انقطاع الشبكة.
                    "startDownload" -> {
                        val url = call.argument<String>("url") ?: ""
                        result.success(startUpdateDownload(url))
                    }
                    // حالة التنزيل الجاري (status/bytes/total/path).
                    "queryDownload" -> {
                        val id = (call.argument<Number>("id") ?: -1L).toLong()
                        result.success(queryUpdateDownload(id))
                    }
                    // (2026-09-22) يفتح مجلد التنزيلات العام (Download/Nexora)
                    // في مستندات النظام — نقرة إشعار اكتمال التحديث.
                    "openDownloadsFolder" -> result.success(openDownloadsFolder())
                    else -> result.notImplemented()
                }
            }
    }

    // ============ التسجيل الصوتي (رسائل الدردشة) ============

    private var audioRecorder: android.media.MediaRecorder? = null

    /** يبدأ تسجيلاً صوتياً AAC/m4a إلى المسار المحدد. */
    private fun startAudioRecording(path: String): Boolean = try {
        stopAudioRecording()
        val r = if (android.os.Build.VERSION.SDK_INT >= 31) {
            android.media.MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION") android.media.MediaRecorder()
        }
        r.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(android.media.MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.AAC)
        r.setAudioEncodingBitRate(64000)
        r.setAudioSamplingRate(44100)
        r.setOutputFile(path)
        r.prepare()
        r.start()
        audioRecorder = r
        true
    } catch (e: Exception) {
        audioRecorder = null
        false
    }

    /** يوقف التسجيل الجاري. */
    private fun stopAudioRecording(): Boolean = try {
        audioRecorder?.let { it.stop(); it.release() }
        val had = audioRecorder != null
        audioRecorder = null
        had
    } catch (e: Exception) {
        audioRecorder = null
        false
    }

    /** يشغّل ملفاً صوتياً من مسار كامل (رسالة صوتية مستلمة). */
    private fun playAudioFile(path: String): Boolean = try {
        val f = File(path)
        if (!f.exists()) false else {
            mediaPlayer?.release()
            mediaPlayer = android.media.MediaPlayer().apply {
                setDataSource(path)
                setOnCompletionListener { it.release() }
                prepare()
                start()
            }
            true
        }
    } catch (e: Exception) { false }

    /** يفتح ملفاً بتطبيق النظام المناسب عبر FileProvider. */
    private fun openFileWithSystem(path: String): Boolean = try {
        val src = File(path)
        if (!src.exists()) false else {
            val shared = copyToShared(src)
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", shared
            )
            val mime = android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(src.extension.lowercase())
                ?: "*/*"
            launch(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        }
    } catch (e: Exception) { false }

    /** يشغّل ملف صوت من res/raw فوق أي صوت آخر (بدون مقاطعة الموسيقى طويلاً). */
    private fun playRaw(name: String): Boolean = try {
        val resId = resources.getIdentifier(name, "raw", packageName)
        if (resId == 0) false else {
            mediaPlayer?.release()
            mediaPlayer = android.media.MediaPlayer.create(this, resId)?.apply {
                setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_EVENT)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setOnCompletionListener { it.release() }
                start()
            }
            mediaPlayer != null
        }
    } catch (e: Exception) { false }

    /** اهتزاز بمدة محددة (يدعم أندرويد الحديث والقديم). */
    private fun vibrateMs(ms: Long) {
        try {
            val vibrator = if (android.os.Build.VERSION.SDK_INT >= 31) {
                val vm = getSystemService(android.content.Context.VIBRATOR_MANAGER_SERVICE)
                    as android.os.VibratorManager
                vm.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(android.content.Context.VIBRATOR_SERVICE)
                    as android.os.Vibrator
            }
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                vibrator.vibrate(
                    android.os.VibrationEffect.createOneShot(
                        ms, android.os.VibrationEffect.DEFAULT_AMPLITUDE
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(ms)
            }
        } catch (e: Exception) { /* الاهتزاز كمالي */ }
    }

    /**
     * إشعار نظام خارجي بصوت مخصص من res/raw — قناة مستقلة لكل صوت لأن
     * صوت القناة لا يتغير بعد إنشائها في أندرويد 8+.
     */
    private fun showNotification(
        title: String,
        body: String,
        sound: String,
        entityType: String = "",
        entityId: String = "",
    ): Boolean = try {
        val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
            as android.app.NotificationManager
        val channelId = "nexora_$sound"
        // (دفعة 58 — متطلب 7) sound == "silent": إشعار صامت تماماً (كتم شامل).
        val silent = sound == "silent"
        val soundUri = Uri.parse("android.resource://$packageName/raw/$sound")
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val ch = android.app.NotificationChannel(
                channelId,
                if (silent) "تنبيهات نكسورا (صامتة)" else "تنبيهات نكسورا",
                if (silent) android.app.NotificationManager.IMPORTANCE_LOW
                else android.app.NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "إشعارات مهمة بصوت مميز"
                if (silent) {
                    enableVibration(false)
                    setSound(null, null)
                } else {
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 350, 150, 350)
                    setSound(
                        soundUri,
                        android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                }
            }
            nm.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            // نقرة الإشعار تحمل بيانات الكيان لفتح السجل المقصود داخل التطبيق.
            if (entityType.isNotEmpty()) {
                putExtra("nx_entity_type", entityType)
                putExtra("nx_entity_id", entityId)
            }
        }
        // requestCode فريد لكل إشعار حتى لا تتشارك الإشعارات نفس الـ extras.
        val pi = android.app.PendingIntent.getActivity(
            this, (System.currentTimeMillis() % 100000).toInt(), launch,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (android.os.Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this).apply {
                if (!silent) {
                    setSound(soundUri)
                    setVibrate(longArrayOf(0, 350, 150, 350))
                }
            }
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify((System.currentTimeMillis() % 100000).toInt(), notification)
        true
    } catch (e: Exception) { false }

    /**
     * يبدأ تنزيل التحديث عبر DownloadManager (خدمة نظام):
     * - يستمر في الخلفية حتى بعد إغلاق التطبيق نهائياً.
     * - يستأنف تلقائياً بعد انقطاع الشبكة (يدعم HTTP Range).
     * - أسرع من تنزيل داخل عملية التطبيق لأنه لا يتأثر بخمول/كبح التطبيق.
     * يعيد معرّف التنزيل، أو -1 عند الفشل.
     */
    /** (2026-09-22) مجلد التحديثات العام في الهاتف: Download/Nexora. */
    private fun publicUpdateDir(): File = File(
        android.os.Environment.getExternalStoragePublicDirectory(
            android.os.Environment.DIRECTORY_DOWNLOADS
        ),
        "Nexora"
    )

    private fun startUpdateDownload(url: String): Long = try {
        val dm = getSystemService(android.content.Context.DOWNLOAD_SERVICE)
            as android.app.DownloadManager
        // نظّف ملفات تحديث قديمة حتى لا تتراكم (المجلد العام + الخاص القديم).
        try {
            publicUpdateDir().mkdirs()
            publicUpdateDir().listFiles()?.forEach { it.delete() }
        } catch (_: Exception) {}
        getExternalFilesDir("updates")?.listFiles()?.forEach { it.delete() }
        val req = android.app.DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("تحديث مدير الحسابات")
            setDescription("جارٍ تنزيل التحديث…")
            setMimeType("application/vnd.android.package-archive")
            // إشعار النظام يظهر اكتمال التنزيل أيضاً (خدمة النظام نفسها).
            setNotificationVisibility(
                android.app.DownloadManager.Request
                    .VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            // (2026-09-22) الحفظ في مجلد عام مخصص Download/Nexora — مرئي
            // للمستخدم في مدير الملفات ولا يضخّم تخزين التطبيق الخاص.
            setDestinationInExternalPublicDir(
                android.os.Environment.DIRECTORY_DOWNLOADS,
                "Nexora/nexora-update.apk"
            )
        }
        dm.enqueue(req)
    } catch (e: Exception) { -1L }

    /**
     * (2026-09-22) يفتح مجلد التنزيلات في مستندات النظام — سلسلة محاولات:
     * مجلد Nexora مباشرة، ثم Downloads، ثم إعدادات التخزين كحل أخير.
     */
    private fun openDownloadsFolder(): Boolean {
        val attempts = listOf(
            "content://com.android.externalstorage.documents/document/primary%3ADownload%2FNexora",
            "content://com.android.externalstorage.documents/tree/primary%3ADownload",
        )
        for (uri in attempts) {
            try {
                val i = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(Uri.parse(uri), "vnd.android.document/directory")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (launch(i)) return true
            } catch (_: Exception) {}
        }
        return try {
            launch(
                Intent(android.provider.Settings.ACTION_INTERNAL_STORAGE_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) { false }
    }

    /** حالة تنزيل جارٍ: خريطة {status, bytes, total, path, reason}. */
    private fun queryUpdateDownload(id: Long): Map<String, Any> {
        val out = mutableMapOf<String, Any>(
            "status" to "unknown", "bytes" to 0L, "total" to -1L, "path" to ""
        )
        if (id < 0) return out
        try {
            val dm = getSystemService(android.content.Context.DOWNLOAD_SERVICE)
                as android.app.DownloadManager
            val c = dm.query(android.app.DownloadManager.Query().setFilterById(id))
            c?.use {
                if (!it.moveToFirst()) return out
                val status = it.getInt(
                    it.getColumnIndexOrThrow(android.app.DownloadManager.COLUMN_STATUS)
                )
                out["bytes"] = it.getLong(
                    it.getColumnIndexOrThrow(
                        android.app.DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR
                    )
                )
                out["total"] = it.getLong(
                    it.getColumnIndexOrThrow(
                        android.app.DownloadManager.COLUMN_TOTAL_SIZE_BYTES
                    )
                )
                out["reason"] = it.getInt(
                    it.getColumnIndexOrThrow(android.app.DownloadManager.COLUMN_REASON)
                )
                out["status"] = when (status) {
                    android.app.DownloadManager.STATUS_SUCCESSFUL -> "done"
                    android.app.DownloadManager.STATUS_FAILED -> "failed"
                    android.app.DownloadManager.STATUS_PAUSED -> "paused"
                    android.app.DownloadManager.STATUS_PENDING -> "pending"
                    else -> "running"
                }
                if (status == android.app.DownloadManager.STATUS_SUCCESSFUL) {
                    // (2026-09-22) المجلد العام أولاً؛ ملف الإصدار القديم
                    // (التخزين الخاص) يبقى مدعوماً لاستئنافات ما قبل الترقية.
                    val pub = File(publicUpdateDir(), "nexora-update.apk")
                    val legacy = File(getExternalFilesDir("updates"), "nexora-update.apk")
                    val f = if (pub.exists()) pub else legacy
                    if (f.exists()) out["path"] = f.absolutePath
                }
            }
        } catch (e: Exception) { /* تُعاد "unknown" */ }
        return out
    }

    /** يفتح شاشة تثبيت النظام لملف APK عبر FileProvider (لا تثبيت صامت). */
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) return "file_missing"
        val uri: Uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: Exception) {
            return "uri_failed"
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (launch(intent)) "ok" else "launch_failed"
    }

    private fun installedPackages(): List<String> =
        waPackages.filter { p ->
            try { packageManager.getPackageInfo(p, 0); true }
            catch (e: PackageManager.NameNotFoundException) { false }
        }

    /**
     * يفتح محادثة الرقم مباشرة داخل واتساب مع الصورة والنص دون تكرار أو نوافذ اختيار متعددة.
     */
    private fun send(phone: String, text: String, path: String?, pkg: String?): String {
        val digits = phone.filter { it.isDigit() }
        if (digits.length < 8) return "bad_phone"

        val target = pkg?.takeIf { it in installedPackages() }
            ?: installedPackages().firstOrNull()
            ?: return "no_whatsapp"

        val file = path?.let { File(it) }
            ?.takeIf { it.exists() && it.length() > 0L }
            ?.let { src -> copyToShared(src) }

        if (file != null) {
            val uri: Uri = try {
                FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            } catch (e: Exception) {
                return "image_failed"
            }

            val jid = "$digits@s.whatsapp.net"
            grantUriPermission(target, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)

            // 1. فتح واتساب المحدد مباشرة مع رقم المحادثة والمرفق
            val withJid = imageIntent(target, uri, text, jid, includeJid = true)
            if (launch(withJid)) return "ok"

            // 2. محاولة عبر ContactPicker للحزمة المحددة
            val direct = imageIntent(target, uri, text, jid, includeJid = true).apply {
                setClassName(target, "com.whatsapp.ContactPicker")
            }
            if (launch(direct)) return "ok"

            // 3. مشاركة الصورة والنص داخل الحزمة المحددة فقط دون تعميم
            val plain = imageIntent(target, uri, text, jid, includeJid = false)
            if (launch(plain)) return "ok"

            return "image_failed"
        }

        return sendTextOnly(digits, text, target)
    }

    /** يبني Intent صورة مع النص المرافق، مع منح واتساب صلاحية قراءة الملف. */
    private fun imageIntent(
        target: String?,
        uri: Uri,
        text: String,
        jid: String,
        includeJid: Boolean,
    ): Intent = Intent(Intent.ACTION_SEND).apply {
        target?.let { setPackage(it) }
        type = "image/*"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TEXT, text)
        putExtra(Intent.EXTRA_TITLE, "سند العملية")
        if (includeJid) putExtra("jid", jid)
        clipData = ClipData.newUri(contentResolver, "voucher", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun sendTextOnly(digits: String, text: String, target: String): String {
        val encoded = Uri.encode(text)
        
        // 1. الرابط المباشر للواجهة البرمجية لواتساب بالحزمة المحددة
        val directApi = Intent(Intent.ACTION_VIEW, Uri.parse("https://api.whatsapp.com/send?phone=$digits&text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(directApi)) return "ok"

        // 2. المخطط المباشر whatsapp:// بالحزمة المحددة
        val schemeIntent = Intent(Intent.ACTION_VIEW, Uri.parse("whatsapp://send?phone=$digits&text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(schemeIntent)) return "ok"

        // 3. رابط wa.me المباشر
        val viaLink = Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/$digits?text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(viaLink)) return "ok"

        return "error:تعذّر فتح المحادثة"
    }

    private fun launch(intent: Intent): Boolean = try {
        startActivity(intent); true
    } catch (e: Exception) { false }

    /** FileProvider يتطلّب مسارًا معلنًا في file_paths.xml. */
    private fun copyToShared(src: File): File = try {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val dst = File(dir, src.name)
        src.copyTo(dst, overwrite = true)
        dst
    } catch (e: Exception) { src }
}
