package space.ulya.vpn

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.TileService
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import org.telegram.login.TelegramLogin

class MainActivity: FlutterActivity() {

    private val CHANNEL = "apps.channel"
    private val NETWORK_CHANNEL = "ulya/network_events"
    private val TELEGRAM_CHANNEL = "ulya/telegram_login"

    // Telegram OIDC client (from @BotFather → Login Widget). The redirect URI
    // is the auto-verified App Link; the SDK delivers the result back to this
    // activity via onNewIntent.
    private val TELEGRAM_CLIENT_ID = "8380612257"
    private val TELEGRAM_REDIRECT_URI = "https://app982852799-login.tg.dev/tglogin"
    private var telegramInited = false
    // Pending reply for an in-flight Dart `login` call.
    private var telegramResult: MethodChannel.Result? = null

    // PackageManager look-ups and bitmap work are slow (binder calls, drawable
    // inflation, compression) — never run them on the platform main thread or
    // every icon request janks the UI for tens of milliseconds.
    private val appsExecutor = Executors.newFixedThreadPool(2)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // Icons are rendered at 32dp in the picker; 64px covers 2x density while
    // keeping the PNG payload ~2 KB instead of 100+ KB for a raw 432px
    // adaptive icon.
    private val ICON_SIZE = 64

    // Pending action delivered by a launcher shortcut or the QS tile
    // ("toggle" | "servers"). Consumed once by the Dart side via
    // getLaunchAction.
    private var launchAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchAction = intent?.getStringExtra("shortcut_action")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // App was already running (singleTop) — remember the action; the Dart
        // side polls it on resume.
        launchAction = intent.getStringExtra("shortcut_action")

        // Telegram Login App Link redirect (https://app{id}-login.tg.dev/tglogin).
        val data = intent.data
        if (data != null && data.host?.endsWith("-login.tg.dev") == true) {
            TelegramLogin.handleLoginResponse(
                data,
                onSuccess = { loginData ->
                    telegramResult?.success(loginData.idToken)
                    telegramResult = null
                },
                onError = { error ->
                    telegramResult?.error("TG_LOGIN_FAILED", error.message, null)
                    telegramResult = null
                },
            )
        }
    }

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

        // Telegram Native Login (app-to-app OIDC). Dart calls `login`; the SDK
        // opens Telegram (or browser fallback) and the result arrives via the
        // App Link in onNewIntent, which replies to the stored result.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TELEGRAM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "login" -> {
                        // Reject overlapping calls.
                        telegramResult?.error("TG_BUSY", "Login already in progress", null)
                        telegramResult = result
                        try {
                            if (!telegramInited) {
                                TelegramLogin.init(
                                    clientId = TELEGRAM_CLIENT_ID,
                                    redirectUri = TELEGRAM_REDIRECT_URI,
                                    scopes = listOf("profile"),
                                )
                                telegramInited = true
                            }
                            TelegramLogin.startLogin(this)
                        } catch (e: Exception) {
                            telegramResult?.error("TG_START_FAILED", e.message, null)
                            telegramResult = null
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->

                when (call.method) {

                    "getLaunchAction" -> {
                        result.success(launchAction)
                        launchAction = null // consume-once
                    }

                    // Pushed by Dart every time the actual VPN tunnel state
                    // flips. VpnTileService reads this flag directly instead
                    // of asking Android "is any VPN active system-wide" —
                    // that used to light the tile up for a different app's
                    // VPN connection too.
                    "setVpnConnected" -> {
                        val connected = call.argument<Boolean>("connected") ?: false
                        getSharedPreferences(VpnTileService.PREFS_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .putBoolean(VpnTileService.PREF_CONNECTED, connected)
                            .apply()
                        requestTileRefresh()
                        result.success(null)
                    }

                    // Pushed by Dart whenever the selected server (or its
                    // resolved config) changes — lets the tile connect to
                    // *this exact* server directly, without opening the app.
                    "setVpnConfig" -> {
                        val remark = call.argument<String>("remark") ?: ""
                        val config = call.argument<String>("config")
                        @Suppress("UNCHECKED_CAST")
                        val blockedApps = (call.argument<List<String>>("blockedApps") ?: emptyList())
                            .toSet()
                        if (config == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        getSharedPreferences(VpnTileService.PREFS_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .putString(VpnTileService.PREF_REMARK, remark)
                            .putString(VpnTileService.PREF_CONFIG, config)
                            .putStringSet(VpnTileService.PREF_BLOCKED_APPS, blockedApps)
                            .apply()
                        result.success(null)
                    }

                    "clearVpnConfig" -> {
                        getSharedPreferences(VpnTileService.PREFS_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .remove(VpnTileService.PREF_REMARK)
                            .remove(VpnTileService.PREF_CONFIG)
                            .remove(VpnTileService.PREF_BLOCKED_APPS)
                            .apply()
                        result.success(null)
                    }

                    // Stable per-device id (survives app uninstall/reinstall as long
                    // as the signing key and device don't change) — used by
                    // RemnawaveService to derive a HWID that doesn't burn a fresh
                    // device slot on every reinstall. Resets on factory reset.
                    "getAndroidId" -> {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID
                        )
                        result.success(id)
                    }

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

    /// Nudges the QS tile to refresh immediately even if the quick-settings
    /// shade isn't currently pulled down (otherwise it'd only catch up the
    /// next time the panel is opened).
    private fun requestTileRefresh() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            TileService.requestListeningState(
                this,
                ComponentName(this, VpnTileService::class.java)
            )
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
