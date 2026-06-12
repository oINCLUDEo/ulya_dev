package space.ulya.vpn

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.ConnectivityManager
import android.net.Network
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {

    private val CHANNEL = "apps.channel"
    private val NETWORK_CHANNEL = "ulya/network_events"

    // PackageManager look-ups and bitmap work are slow (binder calls, drawable
    // inflation, compression) — never run them on the platform main thread or
    // every icon request janks the UI for tens of milliseconds.
    private val appsExecutor = Executors.newFixedThreadPool(2)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // Icons are rendered at 32dp in the picker; 64px covers 2x density while
    // keeping the PNG payload ~2 KB instead of 100+ KB for a raw 432px
    // adaptive icon.
    private val ICON_SIZE = 64

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Default-network change events (Wi-Fi <-> LTE switches). The Dart
        // side re-probes server availability as soon as the network flips so
        // the UI never shows stale "unavailable" states until a manual reload.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var connectivityManager: ConnectivityManager? = null
                private var callback: ConnectivityManager.NetworkCallback? = null
                private val mainHandler = Handler(Looper.getMainLooper())

                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    connectivityManager = cm
                    val cb = object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            mainHandler.post { events.success("available") }
                        }
                        override fun onLost(network: Network) {
                            mainHandler.post { events.success("lost") }
                        }
                    }
                    callback = cb
                    cm.registerDefaultNetworkCallback(cb)
                }

                override fun onCancel(arguments: Any?) {
                    callback?.let { connectivityManager?.unregisterNetworkCallback(it) }
                    callback = null
                    connectivityManager = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->

                when (call.method) {

                    "getInstalledApps" -> appsExecutor.execute {
                        try {
                            val pm = packageManager
                            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)

                            val list = apps
                                .filter { pm.getLaunchIntentForPackage(it.packageName) != null }
                                .map {
                                    mapOf(
                                        "packageName" to it.packageName,
                                        "appName" to pm.getApplicationLabel(it).toString()
                                    )
                                }

                            mainHandler.post { result.success(list) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("ERROR", e.message, null) }
                        }
                    }

                    "getAppIcon" -> {
                        val packageName = call.argument<String>("packageName")

                        if (packageName == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }

                        appsExecutor.execute {
                            val bytes = renderIconPng(packageName)
                            mainHandler.post { result.success(bytes) }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /// Draws the app icon straight into an ICON_SIZE bitmap (no full-size
    /// intermediate) and compresses it to PNG off the main thread.
    private fun renderIconPng(packageName: String): ByteArray? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bmp = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            if (drawable is BitmapDrawable && drawable.bitmap != null) {
                val src = drawable.bitmap
                canvas.drawBitmap(
                    src,
                    null,
                    android.graphics.RectF(0f, 0f, ICON_SIZE.toFloat(), ICON_SIZE.toFloat()),
                    android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG)
                )
            } else {
                drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
                drawable.draw(canvas)
            }
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
            bmp.recycle()
            stream.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    override fun onDestroy() {
        appsExecutor.shutdown()
        super.onDestroy()
    }
}
