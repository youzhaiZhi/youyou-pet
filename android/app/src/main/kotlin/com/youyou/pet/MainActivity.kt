package com.youyou.pet

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var micResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeBridge(
            this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "youyou/pet"),
        )
    }

    /** 权限请求是异步的，先把 channel 的 result 挂起来。 */
    fun requestMic(result: MethodChannel.Result) {
        micResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_MIC) {
            val ok = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            micResult?.success(ok)
            micResult = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // 纯黑界面：状态栏透明 + 铺满，避免任何系统色边缘。
        super.onCreate(savedInstanceState)
    }

    companion object {
        private const val REQ_MIC = 9001
    }
}