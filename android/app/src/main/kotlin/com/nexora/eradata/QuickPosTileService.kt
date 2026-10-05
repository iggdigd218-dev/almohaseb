package com.nexora.eradata

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import flutter.overlay.window.flutter_overlay_window.OverlayService

/**
 * بلاطة «استعلام نكسورا» في لوحة الإعدادات السريعة (الستارة).
 *
 * عند النقر:
 *  - إن كانت صلاحية الظهور فوق التطبيقات ممنوحة: نرسل أمر تشغيل/إظهار
 *    الزر العائم للتطبيق (الذي يُشغّل OverlayService) ونُبدّل البلاطة إلى نشط.
 *  - إن لم تكن ممنوحة: نفتح التطبيق ليوجّه المستخدم لشاشة إذن أندرويد.
 *
 * حالة البلاطة تُقرأ من `OverlayService.isRunning` (الحقيقة على الجهاز)،
 * فلا تظهر نشطة إلا والفقاعة معروضة فعلاً.
 */
class QuickPosTileService : TileService() {

    private val handler = Handler(Looper.getMainLooper())
    private var syncRunnable: Runnable? = null

    override fun onStartListening() {
        super.onStartListening()
        syncTile()
    }

    override fun onStopListening() {
        syncRunnable?.let { handler.removeCallbacks(it) }
        syncRunnable = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (!canDrawOverlays()) {
            // لا صلاحية: نفتح التطبيق ليقود المستخدم إلى شاشة الإذن الرسمية.
            openApp(needPermission = true)
            return
        }
        openApp(needPermission = false)
        // تحديث متفائل فوري (سلاسة اللمس) ثم تثبيت الحالة الواقعية بعد قليل.
        qsTile?.let {
            it.state = Tile.STATE_ACTIVE
            it.updateTile()
        }
        scheduleSync(SYNC_DELAY_MS)
    }

    /** الحالة الحقيقية من خدمة العرض العائم. */
    private fun syncTile() {
        val t = qsTile ?: return
        t.state = if (OverlayService.isRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        t.updateTile()
    }

    private fun scheduleSync(delayMs: Long) {
        syncRunnable?.let { handler.removeCallbacks(it) }
        val task = Runnable { syncTile() }
        syncRunnable = task
        handler.postDelayed(task, delayMs)
    }

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun openApp(needPermission: Boolean) {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_QUICK_POS
            putExtra(EXTRA_NEED_PERMISSION, needPermission)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            startActivityAndCollapse(PendingIntent.getActivity(this, REQ_CODE, intent, flags))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        const val EXTRA_NEED_PERMISSION = "nx_overlay_permission"
        private const val REQ_CODE = 4791
        private const val SYNC_DELAY_MS = 2500L
    }
}
