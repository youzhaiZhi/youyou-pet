package com.youyou.pet

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.sin

/**
 * 常驻的流式 PCM 播放器。
 *
 * 低延迟的关键：
 *  - AudioTrack 只创建一次，之后一直复用（创建一次要 20~50ms，重创建会直接吃掉首音预算）
 *  - MODE_STREAM + 小缓冲（约 30~60ms），写入用 WRITE_BLOCKING
 *  - 数据由独立高优先级线程消费，绝不阻塞平台主线程
 *  - 支持"已写入但未播出"的毫秒数查询，用于判定首音是否真的出来了
 */
internal class PcmPlayer(private val sampleRate: Int) {

    private val bytesPerMs = sampleRate * 2 / 1000.0
    private val queue = LinkedBlockingQueue<Any>()
    private val marker = Any()

    @Volatile private var track: AudioTrack? = null
    @Volatile private var running = false
    @Volatile private var playing = false
    @Volatile private var started = false
    private var worker: Thread? = null
    private var writtenFrames = 0L
    private val pendingBytes = AtomicInteger(0)

    var onDrained: (() -> Unit)? = null
    var onStarted: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    fun start() {
        if (running) return
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        // 缓冲越小延迟越低，但要留出抗卡顿余量。
        val bufSize = maxOf(if (minBuf > 0) minBuf else 4800, 3600)
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        track = builder.build()
        running = true
        worker = Thread({ loop() }, "youyou-pcm").also {
            it.priority = Thread.MAX_PRIORITY
            it.isDaemon = true
            it.start()
        }
    }

    private fun loop() {
        while (running) {
            val item = try {
                queue.take()
            } catch (e: InterruptedException) {
                break
            }
            if (item === marker) {
                drainAndIdle()
                continue
            }
            val data = item as ByteArray
            val t = track ?: continue
            if (!playing) {
                try {
                    t.play()
                } catch (_: Exception) {
                }
                playing = true
            }
            var off = 0
            while (off < data.size && running) {
                val n = try {
                    t.write(data, off, data.size - off, AudioTrack.WRITE_BLOCKING)
                } catch (e: Exception) {
                    onError?.invoke(e.message ?: "write failed")
                    break
                }
                if (n <= 0) break
                off += n
                writtenFrames += n / 2
                pendingBytes.addAndGet(-n)
                if (!started && t.playbackHeadPosition > 0) {
                    started = true
                    onStarted?.invoke()
                }
            }
        }
    }

    /** 在**工作线程内**等待缓冲播空后进入空闲（此时不会有并发 write，pause/flush 是安全的）。 */
    private fun drainAndIdle() {
        val t = track
        val deadline = System.currentTimeMillis() + 10000
        while (running && t != null && System.currentTimeMillis() < deadline) {
            val head = try {
                t.playbackHeadPosition.toLong()
            } catch (_: Exception) {
                0L
            }
            if (head >= writtenFrames) break
            try {
                Thread.sleep(8)
            } catch (_: InterruptedException) {
                break
            }
        }
        if (queue.isEmpty()) {
            try {
                t?.pause()
                t?.flush()
            } catch (_: Exception) {
            }
            writtenFrames = 0
            playing = false
            started = false
        }
        onDrained?.invoke()
    }

    fun write(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        pendingBytes.addAndGet(bytes.size)
        queue.offer(bytes)
    }

    fun mark() {
        queue.offer(marker)
    }

    /** 打断（barge-in）。用 stop() 而不是 pause()，因为 stop() 会解除阻塞中的 write。 */
    fun stop() {
        queue.clear()
        pendingBytes.set(0)
        try {
            track?.stop()
            track?.flush()
        } catch (_: Exception) {
        }
        writtenFrames = 0
        playing = false
        started = false
    }

    fun release() {
        running = false
        queue.clear()
        worker?.interrupt()
        worker = null
        try {
            track?.release()
        } catch (_: Exception) {
        }
        track = null
    }

    /** 还有多少毫秒的语音没有被听到。 */
    fun pendingMs(): Int {
        val t = track
        val head = try {
            t?.playbackHeadPosition?.toLong() ?: 0L
        } catch (_: Exception) {
            0L
        }
        val buffered = (writtenFrames - head).coerceAtLeast(0L)
        val ms = pendingBytes.get() / bytesPerMs + buffered / sampleRate * 1000.0
        return ms.toInt()
    }

    fun isPlaying(): Boolean = playing || pendingBytes.get() > 0
}

/**
 * 占位音：首音迟迟不来时给一个极短的柔和提示音，
 * 走独立的一次性轨道，不占用主队列（否则反而会把真声音推迟）。
 */
internal object Blip {

    fun play() {
        Thread {
            var tr: AudioTrack? = null
            try {
                val sr = 22050
                val durMs = 210
                val n = sr * durMs / 1000
                val buf = ShortArray(n)
                for (i in 0 until n) {
                    val t = i.toDouble() / sr
                    val env = sin(PI * i / n) // 首尾归零，避免爆音
                    buf[i] = (sin(2 * PI * 587.33 * t) * 0.13 * env * 32767).toInt().toShort()
                }
                tr = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sr)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(n * 2)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                tr.write(buf, 0, n)
                tr.play()
                Thread.sleep((durMs + 80).toLong())
            } catch (_: Exception) {
            } finally {
                try {
                    tr?.release()
                } catch (_: Exception) {
                }
            }
        }.start()
    }
}