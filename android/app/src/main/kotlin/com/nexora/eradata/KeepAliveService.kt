package com.nexora.eradata

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * خدمة أمامية تُبقي التطبيق يقظاً وهو داخل مجموعة مزامنة:
 * تمنع النظام من قتل العملية أو تجميد الشبكة أثناء سكون الهاتف والشاشة
 * مطفأة، فيستمر خادم LAN في استقبال العمليات والرسائل والإشعارات فوراً.
 * إشعار دائم صامت (IMPORTANCE_MIN) يعلم المستخدم أن المزامنة نشطة.
 */
class KeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        // قفل يقظة جزئي: المعالج يبقى حياً لاستقبال طلبات LAN والشاشة مطفأة.
        if (wakeLock == null) {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK, "nexora:groupSync"
                ).apply { setReferenceCounted(false); acquire() }
            } catch (_: Exception) { /* اليقظة كمالية */ }
        }
        // قفل Wi-Fi: يمنع النظام من إسبات راديو الشبكة أثناء السكون —
        // بدونه يبقى المعالج حياً لكن خادم LAN ومستمع SSE بلا شبكة.
        if (wifiLock == null) {
            try {
                val wm = applicationContext
                    .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wm.createWifiLock(
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "nexora:groupSyncWifi"
                ).apply { setReferenceCounted(false); acquire() }
            } catch (_: Exception) { /* كمالية */ }
        }
        // START_STICKY: النظام يعيد تشغيل الخدمة إذا قتلها لضغط الذاكرة.
        return START_STICKY
    }

    override fun onDestroy() {
        try { wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
        try { wifiLock?.release() } catch (_: Exception) {}
        wifiLock = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "مزامنة المجموعة النشطة",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "يبقي المزامنة الفورية تعمل في الخلفية"
                setShowBadge(false)
            }
            nm.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setContentTitle("المزامنة الفورية نشطة")
            .setContentText("يستقبل جهازك عمليات المجموعة وإشعاراتها فوراً")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "nexora_keepalive"
        private const val NOTIF_ID = 777001

        fun start(ctx: Context) {
            val i = Intent(ctx, KeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (_: Exception) { /* قيود خلفية — سيُعاد عند فتح التطبيق */ }
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, KeepAliveService::class.java)) }
            catch (_: Exception) {}
        }
    }
}
