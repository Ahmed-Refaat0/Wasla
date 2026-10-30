package com.example.wasla

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URLConnection
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val HOTSPOT_CHANNEL = "wasla/local_hotspot"
        private const val DOWNLOADS_CHANNEL = "wasla/downloads"
        private const val INSTALLED_APPS_CHANNEL = "wasla/installed_apps"
        private const val PERMISSION_REQUEST_CODE = 53317
        private const val STORAGE_PERMISSION_REQUEST_CODE = 53318
        private const val DOWNLOAD_RELATIVE_PATH = "Download/Wasla/"
        private val downloadExecutor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "WaslaDownloadPublisher").apply { isDaemon = true }
        }
        private val appQueryExecutor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "WaslaInstalledApps").apply { isDaemon = true }
        }
    }

    private lateinit var hotspotChannel: MethodChannel
    private lateinit var downloadsChannel: MethodChannel
    private lateinit var installedAppsChannel: MethodChannel
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var permissionResult: MethodChannel.Result? = null
    private var hotspotResult: MethodChannel.Result? = null
    private var storagePermissionResult: MethodChannel.Result? = null
    private var pendingDownload: PendingDownload? = null

    private data class PendingDownload(
        val sourcePath: String,
        val fileName: String,
        val result: MethodChannel.Result,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        hotspotChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOTSPOT_CHANNEL,
        )
        hotspotChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startHotspot(result)
                "stop" -> stopHotspot(result)
                else -> result.notImplemented()
            }
        }
        downloadsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOADS_CHANNEL,
        )
        downloadsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "publishDownload" -> publishDownload(call, result)
                else -> result.notImplemented()
            }
        }
        installedAppsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALLED_APPS_CHANNEL,
        )
        installedAppsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listInstalledUserApps" -> listInstalledUserApps(result)
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun listInstalledUserApps(result: MethodChannel.Result) {
        appQueryExecutor.execute {
            try {
                val flags = PackageManager.GET_META_DATA
                val applications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getInstalledApplications(
                        PackageManager.ApplicationInfoFlags.of(flags.toLong()),
                    )
                } else {
                    packageManager.getInstalledApplications(flags)
                }
                val userApps = applications
                    .asSequence()
                    .filter { app ->
                        app.packageName != packageName &&
                            app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM == 0 &&
                            app.flags and android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP == 0
                    }
                    .mapNotNull { app ->
                        val baseApk = app.sourceDir
                        val apkPaths = (listOfNotNull(baseApk) + (app.splitSourceDirs ?: emptyArray()))
                            .distinct()
                            .mapNotNull { path ->
                                val apk = File(path)
                                if (apk.isFile && apk.canRead()) {
                                    apk.canonicalPath
                                } else {
                                    null
                                }
                            }
                        if (apkPaths.isEmpty()) return@mapNotNull null

                        val label = packageManager.getApplicationLabel(app).toString()
                        val icon = try {
                            drawableToPng(packageManager.getApplicationIcon(app))
                        } catch (_: Exception) {
                            null
                        }
                        mapOf(
                            "appName" to label,
                            "packageName" to app.packageName,
                            "versionName" to packageManager.getPackageInfo(
                                app.packageName,
                                0,
                            ).versionName,
                            "apkPaths" to apkPaths,
                            "icon" to icon,
                        )
                    }
                    .sortedBy { (it["appName"] as String).lowercase() }
                    .toList()

                runOnUiThread { result.success(userApps) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "installed_apps_failed",
                        error.message ?: "تعذّر قراءة التطبيقات المثبتة.",
                        null,
                    )
                }
            }
        }
    }

    private fun drawableToPng(drawable: Drawable): ByteArray {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error(
                "unsupported",
                "نقطة الاتصال المحلية تحتاج إلى Android 8 أو أحدث.",
                null,
            )
            return
        }
        hotspotReservation?.let {
            result.success(hotspotCredentials(it))
            return
        }
        if (permissionResult != null || hotspotResult != null) {
            result.error("busy", "جارٍ إعداد نقطة الاتصال بالفعل.", null)
            return
        }

        val missing = requiredPermissions().filter { permission ->
            ContextCompat.checkSelfPermission(this, permission) !=
                PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permissionResult = result
            requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
            return
        }
        requestLocalOnlyHotspot(result)
    }

    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    @Suppress("DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            PERMISSION_REQUEST_CODE -> {
                val result = permissionResult ?: return
                permissionResult = null
                if (grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                ) {
                    requestLocalOnlyHotspot(result)
                } else {
                    result.error(
                        "permission_denied",
                        "اسمح بالإذن المطلوب لإنشاء نقطة الاتصال المحلية.",
                        null,
                    )
                }
            }

            STORAGE_PERMISSION_REQUEST_CODE -> {
                val result = storagePermissionResult ?: return
                storagePermissionResult = null
                val pending = pendingDownload
                pendingDownload = null
                if (grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED } &&
                    pending != null
                ) {
                    publishLegacyDownload(pending)
                } else {
                    result.error(
                        "storage_permission_denied",
                        "اسمح بحفظ الملفات في مجلد التنزيلات.",
                        null,
                    )
                }
            }
        }
    }

    private fun publishDownload(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        if (sourcePath.isNullOrBlank() ||
            fileName.isNullOrBlank() ||
            fileName != File(fileName).name
        ) {
            result.error("invalid_download", "بيانات الملف غير صالحة.", null)
            return
        }
        if (pendingDownload != null || storagePermissionResult != null) {
            result.error("busy", "جارٍ حفظ ملف آخر في مجلد التنزيلات.", null)
            return
        }

        val pending = PendingDownload(sourcePath, fileName, result)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingDownload = pending
            storagePermissionResult = result
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST_CODE,
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            publishMediaStoreDownload(pending)
        } else {
            publishLegacyDownload(pending)
        }
    }

    private fun publishMediaStoreDownload(pending: PendingDownload) {
        runDownloadOperation(pending) {
            val source = checkedSourceFile(pending.sourcePath)
            publishToMediaStore(source, pending.fileName)
        }
    }

    private fun runDownloadOperation(
        pending: PendingDownload,
        operation: () -> Map<String, String>,
    ) {
        downloadExecutor.execute {
            try {
                val savedFile = operation()
                runOnUiThread { pending.result.success(savedFile) }
            } catch (error: Exception) {
                runOnUiThread {
                    pending.result.error(
                        "download_save_failed",
                        error.message ?: "تعذّر حفظ الملف في مجلد التنزيلات.",
                        null,
                    )
                }
            }
        }
    }

    private fun checkedSourceFile(path: String): File {
        val file = File(path)
        if (!file.isFile || !file.canRead()) {
            throw IOException("ملف الاستقبال المؤقت غير متاح للقراءة.")
        }
        return file
    }

    private fun publishToMediaStore(
        source: File,
        requestedName: String,
    ): Map<String, String> {
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val resolver = contentResolver
        val mimeType =
            URLConnection.guessContentTypeFromName(requestedName)
                ?: "application/octet-stream"
        var savedName: String? = null
        var savedUri: android.net.Uri? = null
        for (index in 0 until 10_000) {
            val candidate = uniqueDownloadName(requestedName, index)
            if (downloadExists(collection, candidate)) continue
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, candidate)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    DOWNLOAD_RELATIVE_PATH,
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            savedUri = resolver.insert(collection, values)
                ?: throw IOException("تعذّر إنشاء الملف في مجلد التنزيلات.")
            savedName = candidate
            break
        }
        val uri = savedUri
            ?: throw IOException("تعذّر العثور على اسم متاح في مجلد التنزيلات.")

        try {
            val output = resolver.openOutputStream(uri, "w")
                ?: throw IOException("تعذّر فتح الملف في مجلد التنزيلات.")
            source.inputStream().buffered().use { input ->
                output.buffered().use { destination ->
                    input.copyTo(destination, 256 * 1024)
                }
            }
            val publishedValues = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            if (resolver.update(uri, publishedValues, null, null) != 1) {
                throw IOException("تعذّر إظهار الملف في مجلد التنزيلات.")
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }

        val name = savedName
            ?: throw IOException("تعذّر تأكيد اسم الملف المحفوظ.")
        return mapOf(
            "path" to "Downloads/Wasla/$name",
            "fileName" to name,
        )
    }

    private fun downloadExists(collection: android.net.Uri, name: String): Boolean {
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        return contentResolver.query(
            collection,
            projection,
            selection,
            arrayOf(name, DOWNLOAD_RELATIVE_PATH),
            null,
        )?.use { cursor -> cursor.moveToFirst() } ?: false
    }

    private fun publishLegacyDownload(pending: PendingDownload) {
        runDownloadOperation(pending) {
            val source = checkedSourceFile(pending.sourcePath)
            @Suppress("DEPRECATION")
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            val targetDirectory = File(downloads, "Wasla")
            if (!targetDirectory.exists() && !targetDirectory.mkdirs()) {
                throw IOException("تعذّر إنشاء مجلد التنزيلات/Wasla.")
            }
            val destination = uniqueLegacyDestination(
                targetDirectory,
                pending.fileName,
            )
            try {
                source.inputStream().buffered().use { input ->
                    destination.outputStream().buffered().use { output ->
                        input.copyTo(output, 256 * 1024)
                    }
                }
            } catch (error: Exception) {
                destination.delete()
                throw error
            }
            mapOf(
                "path" to "Downloads/Wasla/${destination.name}",
                "fileName" to destination.name,
            )
        }
    }

    private fun uniqueLegacyDestination(directory: File, requestedName: String): File {
        for (index in 0 until 10_000) {
            val name = uniqueDownloadName(requestedName, index)
            val candidate = File(directory, name)
            if (candidate.createNewFile()) return candidate
        }
        throw IOException("تعذّر العثور على اسم متاح في مجلد التنزيلات.")
    }

    private fun uniqueDownloadName(name: String, index: Int): String {
        if (index == 0) return name
        val dot = name.lastIndexOf('.')
        val hasExtension = dot > 0
        val stem = if (hasExtension) name.substring(0, dot) else name
        val extension = if (hasExtension) name.substring(dot) else ""
        return "$stem ($index)$extension"
    }

    private fun requestLocalOnlyHotspot(result: MethodChannel.Result) {
        val wifiManager = getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager == null) {
            result.error("unavailable", "خدمة Wi-Fi غير متاحة.", null)
            return
        }

        hotspotResult = result
        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(
                        reservation: WifiManager.LocalOnlyHotspotReservation,
                    ) {
                        hotspotReservation = reservation
                        val pendingResult = hotspotResult
                        hotspotResult = null
                        pendingResult?.success(hotspotCredentials(reservation))
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                        hotspotChannel.invokeMethod("stopped", null)
                    }

                    override fun onFailed(reason: Int) {
                        hotspotReservation = null
                        val pendingResult = hotspotResult
                        hotspotResult = null
                        pendingResult?.error(
                            "start_failed",
                            hotspotFailureMessage(reason),
                            reason,
                        )
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (error: SecurityException) {
            hotspotResult = null
            result.error("permission_denied", error.message, null)
        } catch (error: IllegalStateException) {
            hotspotResult = null
            result.error("start_failed", error.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun hotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
    ): Map<String, String?> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val configuration = reservation.softApConfiguration
            mapOf(
                "ssid" to configuration.getSsid(),
                "passphrase" to configuration.getPassphrase(),
            )
        } else {
            val configuration: WifiConfiguration? = reservation.wifiConfiguration
            mapOf(
                "ssid" to configuration?.SSID?.trim('"'),
                "passphrase" to configuration?.preSharedKey?.trim('"'),
            )
        }

    private fun hotspotFailureMessage(reason: Int): String =
        when (reason) {
            WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
                "لا توجد قناة Wi-Fi متاحة لإنشاء نقطة الاتصال."
            WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC ->
                "تعذّر بدء نقطة الاتصال. أوقف أي نقطة اتصال أخرى وحاول مجددًا."
            WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
                "وضع Wi-Fi الحالي لا يسمح بإنشاء نقطة اتصال محلية."
            WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
                "النظام أو الشركة المصنّعة لا يسمحان بإنشاء نقطة اتصال محلية."
            else -> "تعذّر بدء نقطة الاتصال المحلية (رمز الخطأ $reason)."
        }

    private fun stopHotspot(result: MethodChannel.Result) {
        val reservation = hotspotReservation
        hotspotReservation = null
        reservation?.close()
        result.success(null)
        hotspotChannel.invokeMethod("stopped", null)
    }

    override fun onDestroy() {
        hotspotReservation?.close()
        hotspotReservation = null
        permissionResult = null
        hotspotResult = null
        pendingDownload = null
        storagePermissionResult = null
        super.onDestroy()
    }
}
