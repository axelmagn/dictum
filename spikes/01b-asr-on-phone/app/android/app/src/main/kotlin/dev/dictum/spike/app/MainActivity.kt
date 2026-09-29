package dev.dictum.spike.app

import android.app.ActivityManager
import android.content.Context
import java.io.File
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "dev.dictum.spike/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Keep screen on by default for the benchmark activity
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceInfo" -> {
                    try {
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val memInfo = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(memInfo)

                        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            Build.SOC_MODEL
                        } else {
                            Build.HARDWARE
                        }

                        val extDirFile = context.getExternalFilesDir(null)
                        if (extDirFile != null) {
                            File(extDirFile, "models").mkdirs()
                            File(extDirFile, "audio").mkdirs()
                            File(extDirFile, "out").mkdirs()
                        }
                        val extDir = extDirFile?.absolutePath ?: ""

                        val data = mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "socModel" to socModel,
                            "totalRamBytes" to memInfo.totalMem,
                            "androidRelease" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "cpuCoreCount" to Runtime.getRuntime().availableProcessors(),
                            "externalFilesDir" to extDir
                        )
                        result.success(data)
                    } catch (e: Exception) {
                        result.error("DEVICE_INFO_ERROR", e.message, null)
                    }
                }
                "getThermalStatus" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.currentThermalStatus)
                        } else {
                            result.success(-1)
                        }
                    } catch (e: Exception) {
                        result.error("THERMAL_STATUS_ERROR", e.message, null)
                    }
                }
                "getBatteryStatus" -> {
                    try {
                        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

                        val ifilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                        val batteryStatus = registerReceiver(null, ifilter)
                        val status = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                                         status == BatteryManager.BATTERY_STATUS_FULL

                        result.success(mapOf(
                            "percent" to level,
                            "isCharging" to isCharging
                        ))
                    } catch (e: Exception) {
                        result.error("BATTERY_STATUS_ERROR", e.message, null)
                    }
                }
                "setKeepScreenOn" -> {
                    val enabled = call.arguments as? Boolean ?: true
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
