package com.lanbridge.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.net.Socket
import kotlin.concurrent.thread

/**
 * LanBridge Android 原生主 Activity 桥接层
 * 负责将 Flutter 界面的 MethodChannel 调用桥接到：
 * 1. MediaProjection 手机屏幕实时抓取与 TCP 推流（可投屏给电脑或另一台安卓手机）
 * 2. LanBridgeControlService 无障碍手势反控注入（点击/双击/滑动/返回/桌面）
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lanbridge.app/native_bridge"
    private val REQUEST_MEDIA_PROJECTION = 1001

    private var projectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    @Volatile
    private var isStreaming = false
    private var targetPcIp: String = ""
    private var targetPcPort: Int = 50003

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAccessibilitySettings" -> {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }
                "dispatchRemoteGesture" -> {
                    val svc = LanBridgeControlService.instance
                    if (svc != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        val cmd = call.argument<String>("cmd") ?: ""
                        when (cmd) {
                            "TAP" -> {
                                val x = (call.argument<Double>("x") ?: 0.5).toFloat()
                                val y = (call.argument<Double>("y") ?: 0.5).toFloat()
                                svc.performTap(x, y)
                            }
                            "DOUBLE_TAP" -> {
                                val x = (call.argument<Double>("x") ?: 0.5).toFloat()
                                val y = (call.argument<Double>("y") ?: 0.5).toFloat()
                                svc.performDoubleTap(x, y)
                            }
                            "SWIPE" -> {
                                val x1 = (call.argument<Double>("x1") ?: 0.5).toFloat()
                                val y1 = (call.argument<Double>("y1") ?: 0.5).toFloat()
                                val x2 = (call.argument<Double>("x2") ?: 0.5).toFloat()
                                val y2 = (call.argument<Double>("y2") ?: 0.5).toFloat()
                                val duration = (call.argument<Int>("duration") ?: 240).toLong()
                                svc.performSwipe(x1, y1, x2, y2, duration)
                            }
                            "KEY" -> {
                                val key = call.argument<String>("key") ?: "BACK"
                                svc.performSystemNav(key)
                            }
                        }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "startScreenCapture" -> {
                    targetPcIp = call.argument<String>("targetIp") ?: ""
                    targetPcPort = call.argument<Int>("port") ?: 50003
                    val captureIntent = projectionManager?.createScreenCaptureIntent()
                    if (captureIntent != null) {
                        startActivityForResult(captureIntent, REQUEST_MEDIA_PROJECTION)
                    }
                    result.success(true)
                }
                "stopScreenCapture" -> {
                    stopStreaming()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MEDIA_PROJECTION && resultCode == Activity.RESULT_OK && data != null) {
            mediaProjection = projectionManager?.getMediaProjection(resultCode, data)
            startStreamingToPeer()
        }
    }

    private fun startStreamingToPeer() {
        val dm = resources.displayMetrics
        val width = 720
        val height = (dm.heightPixels.toFloat() / dm.widthPixels.toFloat() * width).toInt()
        val density = dm.densityDpi

        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "LanBridgeScreen",
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            Handler(Looper.getMainLooper())
        )

        isStreaming = true
        thread(start = true) {
            try {
                Socket(targetPcIp, targetPcPort).use { socket ->
                    val out = DataOutputStream(socket.getOutputStream())
                    while (isStreaming) {
                        val image = imageReader?.acquireLatestImage()
                        if (image != null) {
                            val planes = image.planes
                            val buffer = planes[0].buffer
                            val pixelStride = planes[0].pixelStride
                            val rowStride = planes[0].rowStride
                            val rowPadding = rowStride - pixelStride * width

                            val bitmap = Bitmap.createBitmap(
                                width + rowPadding / pixelStride,
                                height,
                                Bitmap.Config.ARGB_8888
                            )
                            bitmap.copyPixelsFromBuffer(buffer)
                            image.close()

                            val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
                            val baos = ByteArrayOutputStream()
                            cropped.compress(Bitmap.CompressFormat.JPEG, 68, baos)
                            val bytes = baos.toByteArray()

                            out.writeInt(bytes.size)
                            out.write(bytes)
                            out.flush()
                        }
                        Thread.sleep(45)
                    }
                }
            } catch (_: Exception) {
            } finally {
                stopStreaming()
            }
        }
    }

    private fun stopStreaming() {
        isStreaming = false
        try {
            virtualDisplay?.release()
            imageReader?.close()
            mediaProjection?.stop()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        imageReader = null
        mediaProjection = null
    }
}