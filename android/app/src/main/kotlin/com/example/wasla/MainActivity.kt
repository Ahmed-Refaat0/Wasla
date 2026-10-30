package com.example.wasla

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val HOTSPOT_CHANNEL = "wasla/local_hotspot"
        private const val PERMISSION_REQUEST_CODE = 53317
    }

    private lateinit var hotspotChannel: MethodChannel
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var permissionResult: MethodChannel.Result? = null
    private var hotspotResult: MethodChannel.Result? = null

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
        if (requestCode != PERMISSION_REQUEST_CODE) return

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
        super.onDestroy()
    }
}
