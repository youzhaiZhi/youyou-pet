package com.youyou.pet

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * 原生能力入口：流式 PCM 播放 / 系统 TTS / 语音识别 / 安全存储 / 高刷申请。
 * 刻意不引入任何 Flutter 插件 —— 依赖越少，云端构建越稳，链路也越短。
 */
internal class NativeBridge(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())

    private var player: PcmPlayer? = null
    private var playerRate = 0

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsPending: MethodChannel.Result? = null
    private var ttsLocale: Locale? = null
    private var utterSeq = 0

    private var recognizer: SpeechRecognizer? = null

    private var securePrefs: SharedPreferences? = null
    private var prefs: SharedPreferences? = null

    init {
        channel.setMethodCallHandler(this)
    }

    private fun emit(name: String, args: Any? = null) {
        main.post {
            try {
                channel.invokeMethod(name, args)
            } catch (_: Exception) {
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---------------------------------------------------------- 音频
            "audioInit" -> {
                val rate = call.argument<Int>("sampleRate") ?: 24000
                if (player != null && playerRate == rate) {
                    result.success(true)
                    return
                }
                player?.release()
                val p = PcmPlayer(rate)
                p.onDrained = { emit("audioDrained") }
                p.onStarted = { emit("audioStarted") }
                p.onError = { msg -> emit("audioError", mapOf("message" to msg)) }
                try {
                    p.start()
                    player = p
                    playerRate = rate
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "audioWrite" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes != null) player?.write(bytes)
                result.success(null)
            }

            "audioMark" -> {
                player?.mark()
                result.success(null)
            }

            "audioStop" -> {
                player?.stop()
                result.success(null)
            }

            "audioPendingMs" -> result.success(player?.pendingMs() ?: 0)

            "playBlip" -> {
                Blip.play()
                result.success(null)
            }

            // -------------------------------------------------------- 系统 TTS
            "ttsInit" -> {
                if (ttsReady) {
                    result.success(true)
                    return
                }
                ttsPending = result
                if (tts == null) {
                    tts = TextToSpeech(activity) { status ->
                        ttsReady = status == TextToSpeech.SUCCESS
                        if (ttsReady) configureTts()
                        ttsPending?.success(ttsReady)
                        ttsPending = null
                    }
                }
            }

            "ttsSpeak" -> {
                val text = call.argument<String>("text") ?: ""
                val engine = tts
                if (!ttsReady || engine == null || text.isBlank()) {
                    emit("ttsDone")
                    result.success(null)
                    return
                }
                val want = pickLocale(text)
                if (want != ttsLocale) {
                    try {
                        engine.language = want
                        ttsLocale = want
                    } catch (_: Exception) {
                    }
                }
                utterSeq += 1
                engine.speak(text, TextToSpeech.QUEUE_ADD, null, "u$utterSeq")
                result.success(null)
            }

            "ttsStop" -> {
                try {
                    tts?.stop()
                } catch (_: Exception) {
                }
                result.success(null)
            }

            // ---------------------------------------------------------- 语音识别
            "requestMic" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else {
                    (activity as? MainActivity)?.requestMic(result)
                        ?: result.success(false)
                }
            }

            "asrStart" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                    activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    emit("asrError", mapOf("code" to -1))
                    result.success(false)
                    return
                }
                result.success(startAsr())
            }

            "asrStop" -> {
                try {
                    recognizer?.stopListening()
                } catch (_: Exception) {
                }
                result.success(null)
            }

            // ------------------------------------------------------------ 系统
            "highRefreshRate" -> {
                applyHighRefreshRate()
                result.success(null)
            }

            "keepScreenOn" -> {
                val on = call.argument<Boolean>("on") ?: false
                main.post {
                    if (on) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                result.success(null)
            }

            // ------------------------------------------------------------ 存储
            "secretGet" -> {
                val key = call.argument<String>("key") ?: ""
                result.success(secure().getString(key, null))
            }

            "secretSet" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                secure().edit().putString(key, value).apply()
                result.success(null)
            }

            "prefsGet" -> {
                val key = call.argument<String>("key") ?: ""
                result.success(plain().getString(key, null))
            }

            "prefsSet" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                plain().edit().putString(key, value).apply()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ TTS

    private fun configureTts() {
        val engine = tts ?: return
        try {
            engine.setSpeechRate(1.08f)
            engine.setPitch(1.0f)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    emit("ttsStart")
                }

                override fun onDone(utteranceId: String?) {
                    emit("ttsDone")
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    emit("ttsDone")
                }
            })
        } catch (_: Exception) {
        }
    }

    /** 中文文本用中文发音人，其它用系统默认，避免"用英文腔念中文"的灾难。 */
    private fun pickLocale(text: String): Locale {
        val cjk = text.count { it.code in 0x3400..0x9FFF }
        return if (cjk > 0) Locale.SIMPLIFIED_CHINESE else Locale.getDefault()
    }

    // ------------------------------------------------------------------ ASR

    private fun startAsr(): Boolean {
        return try {
            if (recognizer == null) {
                recognizer = SpeechRecognizer.createSpeechRecognizer(activity).apply {
                    setRecognitionListener(object : RecognitionListener {
                        override fun onPartialResults(partialResults: android.os.Bundle?) {
                            val text = partialResults
                                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                                ?.firstOrNull() ?: return
                            emit("asr", mapOf("text" to text, "final" to false))
                        }

                        override fun onResults(results: android.os.Bundle?) {
                            val text = results
                                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                                ?.firstOrNull() ?: ""
                            emit("asr", mapOf("text" to text, "final" to true))
                        }

                        override fun onError(error: Int) {
                            emit("asrError", mapOf("code" to error))
                        }

                        override fun onReadyForSpeech(params: android.os.Bundle?) {}
                        override fun onBeginningOfSpeech() {}
                        override fun onRmsChanged(rmsdB: Float) {}
                        override fun onBufferReceived(buffer: ByteArray?) {}
                        override fun onEndOfSpeech() {}
                        override fun onEvent(eventType: Int, params: android.os.Bundle?) {}
                    })
                }
            }
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            }
            recognizer?.startListening(intent)
            true
        } catch (e: Exception) {
            emit("asrError", mapOf("code" to -2, "message" to (e.message ?: "")))
            false
        }
    }

    // ------------------------------------------------------------- 高刷新率

    /**
     * 显式申请屏幕的最高刷新率模式。Android 默认会把应用限制在 60Hz，
     * 不申请的话 120fps 引擎也只能跑 60。
     */
    private fun applyHighRefreshRate() {
        main.post {
            try {
                val window = activity.window
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val display = activity.display ?: return@post
                    val best = display.supportedModes.maxByOrNull { it.refreshRate } ?: return@post
                    val lp = window.attributes
                    lp.preferredDisplayModeId = best.modeId
                    window.attributes = lp
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    @Suppress("DEPRECATION")
                    val display = window.windowManager.defaultDisplay
                    val best = display.supportedModes.maxByOrNull { it.refreshRate } ?: return@post
                    val lp = window.attributes
                    lp.preferredRefreshRate = best.refreshRate
                    window.attributes = lp
                }
            } catch (_: Exception) {
            }
        }
    }

    // ---------------------------------------------------------------- 存储

    private fun secure(): SharedPreferences {
        securePrefs?.let { return it }
        val created = try {
            val ctx = activity.applicationContext
            val key = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                ctx,
                "youyou_secure",
                key,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (_: Exception) {
            // 少数机型 Keystore 异常时退回应用私有目录，仍然不对外可见。
            activity.applicationContext.getSharedPreferences(
                "youyou_secure_fallback", Context.MODE_PRIVATE
            )
        }
        securePrefs = created
        return created
    }

    private fun plain(): SharedPreferences {
        prefs?.let { return it }
        val p = activity.getSharedPreferences("youyou_prefs", Context.MODE_PRIVATE)
        prefs = p
        return p
    }
}