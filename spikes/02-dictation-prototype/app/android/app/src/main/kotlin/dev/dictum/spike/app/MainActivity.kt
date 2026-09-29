package dev.dictum.spike.app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val DEVICE_CHANNEL = "dev.dictum.spike/device"
    private val AUDIO_CONTROL_CHANNEL = "dev.dictum.spike/audio_control"
    private val AUDIO_STREAM_CHANNEL = "dev.dictum.spike/audio_stream"
    private val AUDIO_PLAYER_CHANNEL = "dev.dictum.spike/audio_player"

    private val RECORD_AUDIO_REQUEST_CODE = 1001
    private var pendingPermissionResult: MethodChannel.Result? = null

    // Audio capture state
    @Volatile private var isRecording = false
    private var recordingThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    @Volatile private var overrunCount = 0
    @Volatile private var totalSamplesRecorded = 0L
    private var recordingStartTime = 0L
    private var activeWavPath: String? = null
    private var audioEventSink: EventChannel.EventSink? = null

    // Audio playback state
    private var mediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 1. Device Channel
        MethodChannel(messenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
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
                "hasAudioPermission" -> {
                    val granted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "requestAudioPermission" -> {
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_AUDIO_REQUEST_CODE)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 2. Audio Control Channel
        MethodChannel(messenger, AUDIO_CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    val wavPath = call.argument<String>("wavPath")
                    if (wavPath == null) {
                        result.error("INVALID_ARGS", "wavPath required", null)
                        return@setMethodCallHandler
                    }
                    val ok = startRecordingInternal(wavPath)
                    result.success(ok)
                }
                "stopRecording" -> {
                    val stats = stopRecordingInternal()
                    result.success(stats)
                }
                "getRecordingStats" -> {
                    result.success(mapOf(
                        "isRecording" to isRecording,
                        "overrunCount" to overrunCount,
                        "totalSamples" to totalSamplesRecorded
                    ))
                }
                else -> result.notImplemented()
            }
        }

        // 3. Audio Stream Channel
        EventChannel(messenger, AUDIO_STREAM_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                audioEventSink = null
            }
        })

        // 4. Audio Player Channel
        MethodChannel(messenger, AUDIO_PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startPlayer" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path required", null)
                        return@setMethodCallHandler
                    }
                    val ok = startPlayerInternal(path)
                    result.success(ok)
                }
                "pausePlayer" -> {
                    result.success(pausePlayerInternal())
                }
                "resumePlayer" -> {
                    result.success(resumePlayerInternal())
                }
                "seekPlayer" -> {
                    val pos = call.argument<Int>("positionMs") ?: 0
                    seekPlayerInternal(pos)
                    result.success(true)
                }
                "stopPlayer" -> {
                    stopPlayerInternal()
                    result.success(true)
                }
                "getPlayerStatus" -> {
                    result.success(getPlayerStatusInternal())
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RECORD_AUDIO_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun startRecordingInternal(wavPath: String): Boolean {
        if (isRecording) return false

        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferSize = maxOf(minBufferSize, sampleRate * 2 * 2) // >= 2 seconds buffer

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
        } catch (e: SecurityException) {
            return false
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }

        val wavFile = File(wavPath)
        wavFile.parentFile?.mkdirs()
        val raf = RandomAccessFile(wavFile, "rw")
        raf.setLength(0)
        // Reserve 44-byte standard WAV header placeholder
        val placeholder = ByteArray(44)
        raf.write(placeholder)

        overrunCount = 0
        totalSamplesRecorded = 0L
        activeWavPath = wavPath
        isRecording = true
        audioRecord = record
        recordingStartTime = System.currentTimeMillis()

        record.startRecording()

        val mainHandler = Handler(Looper.getMainLooper())

        recordingThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

            val frameSizeBytes = 1024 // 512 samples * 2 bytes
            val readBuffer = ByteArray(frameSizeBytes)

            while (isRecording) {
                var bytesRead = 0
                while (bytesRead < frameSizeBytes && isRecording) {
                    val n = record.read(readBuffer, bytesRead, frameSizeBytes - bytesRead)
                    if (n < 0) {
                        overrunCount++
                        break
                    }
                    bytesRead += n
                }

                if (!isRecording) break

                if (bytesRead == frameSizeBytes) {
                    try {
                        raf.write(readBuffer, 0, frameSizeBytes)
                    } catch (e: Exception) {
                        overrunCount++
                    }
                    totalSamplesRecorded += 512

                    val frameCopy = readBuffer.clone()
                    mainHandler.post {
                        audioEventSink?.success(frameCopy)
                    }
                }
            }

            try {
                val totalPcmBytes = totalSamplesRecorded * 2
                writeWavHeader(raf, totalPcmBytes)
                raf.close()
            } catch (e: Exception) {
                // best effort
            }
        }, "AudioRecordThread")

        recordingThread?.start()
        return true
    }

    private fun stopRecordingInternal(): Map<String, Any> {
        val wallClockMs = System.currentTimeMillis() - recordingStartTime
        isRecording = false

        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {}
        audioRecord = null

        try {
            recordingThread?.join(1000)
        } catch (e: InterruptedException) {}
        recordingThread = null

        val path = activeWavPath ?: ""
        val samples = totalSamplesRecorded
        val durationMs = samples * 1000L / 16000L

        return mapOf(
            "wavPath" to path,
            "totalSamples" to samples,
            "totalDurationMs" to durationMs,
            "wallClockMs" to wallClockMs,
            "overrunCount" to overrunCount
        )
    }

    private fun writeWavHeader(file: RandomAccessFile, totalPcmBytes: Long) {
        val totalDataLen = totalPcmBytes + 36
        val sampleRate = 16000
        val channels = 1
        val bitsPerSample = 16
        val byteRate = sampleRate * channels * (bitsPerSample / 8)
        val blockAlign = channels * (bitsPerSample / 8)

        val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(totalDataLen.toInt())
            put("WAVE".toByteArray(Charsets.US_ASCII))
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16) // subchunk1size = 16 for PCM
            putShort(1.toShort()) // audio format 1 = PCM
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort(blockAlign.toShort())
            putShort(bitsPerSample.toShort())
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(totalPcmBytes.toInt())
        }

        file.seek(0)
        file.write(header.array())
    }

    // Audio Player Methods
    private fun startPlayerInternal(path: String): Boolean {
        stopPlayerInternal()
        val file = File(path)
        if (!file.exists()) return false
        return try {
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                setOnCompletionListener {
                    // Reset to beginning on playback completion
                    seekTo(0)
                }
                prepare()
                start()
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun pausePlayerInternal(): Boolean {
        mediaPlayer?.let {
            if (it.isPlaying) {
                it.pause()
                return true
            }
        }
        return false
    }

    private fun resumePlayerInternal(): Boolean {
        mediaPlayer?.let {
            if (!it.isPlaying) {
                it.start()
                return true
            }
        }
        return false
    }

    private fun seekPlayerInternal(positionMs: Int) {
        mediaPlayer?.seekTo(positionMs)
    }

    private fun stopPlayerInternal() {
        mediaPlayer?.let {
            try {
                if (it.isPlaying) it.stop()
                it.release()
            } catch (e: Exception) {}
        }
        mediaPlayer = null
    }

    private fun getPlayerStatusInternal(): Map<String, Any> {
        val mp = mediaPlayer
        return if (mp != null) {
            val isPlaying = try { mp.isPlaying } catch (e: Exception) { false }
            val pos = try { mp.currentPosition } catch (e: Exception) { 0 }
            val dur = try { mp.duration } catch (e: Exception) { 0 }
            mapOf("isPlaying" to isPlaying, "positionMs" to pos, "durationMs" to dur)
        } else {
            mapOf("isPlaying" to false, "positionMs" to 0, "durationMs" to 0)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRecordingInternal()
        stopPlayerInternal()
    }
}
