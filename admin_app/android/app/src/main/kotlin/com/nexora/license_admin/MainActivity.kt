package com.nexora.license_admin

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val updateChannel = "nexora_admin/updates"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(
                        if (Build.VERSION.SDK_INT >= 26)
                            packageManager.canRequestPackageInstalls()
                        else true
                    )
                    "openInstallSettings" -> {
                        result.success(
                            if (Build.VERSION.SDK_INT >= 26) {
                                launch(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            } else true
                        )
                    }
                    "startDownload" -> {
                        val url = call.argument<String>("url") ?: ""
                        result.success(startUpdateDownload(url))
                    }
                    "queryDownload" -> {
                        val id = (call.argument<Number>("id") ?: -1L).toLong()
                        result.success(queryUpdateDownload(id))
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(installApk(path))
                    }
                    "cacheUpdateDir" -> {
                        val dir = File(cacheDir, "updates").apply { mkdirs() }
                        result.success(dir.absolutePath)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun publicUpdateDir(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        "NexoraAdmin"
    )

    private fun startUpdateDownload(url: String): Long = try {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        try {
            publicUpdateDir().mkdirs()
            publicUpdateDir().listFiles()?.forEach { it.delete() }
        } catch (_: Exception) {}
        getExternalFilesDir("updates")?.listFiles()?.forEach { it.delete() }

        val req = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("تحديث مدير التراخيص")
            setDescription("جارٍ تنزيل التحديث الجديد…")
            setMimeType("application/vnd.android.package-archive")
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            setDestinationInExternalPublicDir(
                Environment.DIRECTORY_DOWNLOADS,
                "NexoraAdmin/license-admin-update.apk"
            )
        }
        dm.enqueue(req)
    } catch (e: Exception) {
        -1L
    }

    private fun queryUpdateDownload(id: Long): Map<String, Any> {
        val out = mutableMapOf<String, Any>(
            "status" to "unknown",
            "bytes" to 0L,
            "total" to -1L,
            "path" to ""
        )
        if (id < 0) return out
        try {
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val c = dm.query(DownloadManager.Query().setFilterById(id))
            c?.use {
                if (!it.moveToFirst()) return out
                val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                out["bytes"] = it.getLong(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                )
                out["total"] = it.getLong(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                )
                out["reason"] = it.getInt(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
                )
                out["status"] = when (status) {
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    DownloadManager.STATUS_FAILED -> "failed"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_PENDING -> "pending"
                    else -> "running"
                }
                if (status == DownloadManager.STATUS_SUCCESSFUL) {
                    val pub = File(publicUpdateDir(), "license-admin-update.apk")
                    val legacy = File(getExternalFilesDir("updates"), "license-admin-update.apk")
                    val f = if (pub.exists()) pub else legacy
                    if (f.exists()) out["path"] = f.absolutePath
                }
            }
        } catch (_: Exception) {}
        return out
    }

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

    private fun launch(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }
}
