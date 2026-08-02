package space.ulya.vpn

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.wisecodex.flutter_v2ray.xray.dto.XrayConfig
import com.wisecodex.flutter_v2ray.xray.service.XrayVPNService
import com.wisecodex.flutter_v2ray.xray.utils.AppConfigs
import org.json.JSONObject

/**
 * Quick Settings tile: shows whether the app's own VPN tunnel is active and
 * toggles it on tap.
 *
 * Whenever VPN permission has already been granted *and* Dart has pushed a
 * resolved config for the currently selected server (see
 * MainActivity's "setVpnConfig" handler / NativeVpnBridge), the tile starts
 * or stops [XrayVPNService] directly — same Intent contract the
 * flutter_v2ray_plus plugin itself uses (see its FlutterV2rayPlugin.
 * startVpnService/handleStopVless) — so tapping the tile connects instantly
 * without ever bringing the app to the foreground.
 *
 * Falls back to opening the app (old behaviour) when either condition isn't
 * met: VPN permission can only be granted from a visible Activity (first
 * connect ever), and there's nothing to connect to before a server has been
 * selected at least once.
 */
class VpnTileService : TileService() {

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartListening() {
        super.onStartListening()
        updateState()
        // Network changes don't tell us whether *our* tunnel is up (see
        // isVpnActive below), but they're a reasonable prompt to re-read our
        // own flag in case it went stale — e.g. the system killed our VPN
        // service without Dart getting a chance to report it.
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityManager = cm
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = updateState()
            override fun onLost(network: Network) = updateState()
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = updateState()
        }
        networkCallback = cb
        cm.registerNetworkCallback(
            android.net.NetworkRequest.Builder().build(),
            cb,
        )
    }

    override fun onStopListening() {
        networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        networkCallback = null
        connectivityManager = null
        super.onStopListening()
    }

    private fun updateState() {
        val tile = qsTile ?: return
        tile.state = if (isVpnActive()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        tile.updateTile()
    }

    // Reads the flag Dart pushes via MainActivity's "setVpnConnected" method
    // channel handler. Deliberately NOT "is any VPN active system-wide"
    // (checking NetworkCapabilities.TRANSPORT_VPN) — that lit the tile up
    // for a completely unrelated VPN app's connection too.
    private fun isVpnActive(): Boolean {
        return prefs().getBoolean(PREF_CONNECTED, false)
    }

    private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun onClick() {
        super.onClick()

        if (isVpnActive()) {
            stopVpnDirectly()
            return
        }

        val hasVpnPermission = VpnService.prepare(applicationContext) == null
        val config = prefs().getString(PREF_CONFIG, null)
        if (hasVpnPermission && config != null) {
            val started = runCatching {
                startVpnDirectly(config, prefs().getString(PREF_REMARK, "") ?: "")
            }.isSuccess
            if (started) return
        }

        openApp()
    }

    /// Mirrors FlutterV2rayPlugin.buildXrayConfig + startVpnService: builds
    /// the same [XrayConfig] the Dart-driven path would and sends it to the
    /// same [XrayVPNService] via the same Intent contract.
    private fun startVpnDirectly(configJson: String, remark: String) {
        val blockedApps = prefs().getStringSet(PREF_BLOCKED_APPS, emptySet()) ?: emptySet()

        val xrayConfig = XrayConfig().apply {
            REMARK = remark
            V2RAY_FULL_JSON_CONFIG = configJson
            BLOCKED_APPS = ArrayList(blockedApps)
            NOTIFICATION_DISCONNECT_BUTTON_NAME = "Отключить"
            APPLICATION_NAME = runCatching {
                packageManager.getApplicationLabel(applicationInfo).toString()
            }.getOrDefault("Ulya VPN")
            NOTIFICATION_ICON_RESOURCE_NAME = "ic_launcher"
            NOTIFICATION_ICON_RESOURCE_TYPE = "mipmap"
            APPLICATION_ICON = resources.getIdentifier(
                NOTIFICATION_ICON_RESOURCE_NAME, NOTIFICATION_ICON_RESOURCE_TYPE, packageName
            )
            // Excludes the server's own address from the tunnel — without
            // this the connection to the VPN server itself would loop back
            // through the VPN. Best-effort: a parse failure just leaves the
            // defaults, matching the plugin's own extractServerAddress.
            runCatching {
                val json = JSONObject(configJson)
                val server = json.optJSONArray("outbounds")
                    ?.optJSONObject(0)
                    ?.optJSONObject("settings")
                    ?.optJSONArray("vnext")
                    ?.optJSONObject(0)
                CONNECTED_V2RAY_SERVER_ADDRESS = server?.optString("address", "") ?: ""
                CONNECTED_V2RAY_SERVER_PORT = server?.optInt("port", 0)?.toString() ?: "0"
            }
        }

        Intent(this, XrayVPNService::class.java).apply {
            putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)
            putExtra("V2RAY_CONFIG", xrayConfig)
            putExtra("PROXY_ONLY", false)
        }.also { intent ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        }

        // Optimistic — Dart reconciles the real status the next time the app
        // runs (onStatusChanged reports the current state on fresh
        // subscribe, per _resubscribeVpnStatus), same as any other
        // out-of-band VPN state change.
        prefs().edit().putBoolean(PREF_CONNECTED, true).apply()
        updateState()
    }

    private fun stopVpnDirectly() {
        val intent = Intent(this, XrayVPNService::class.java).apply {
            putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
        }
        try {
            startService(intent)
        } catch (e: Exception) {
            stopService(intent)
        }
        prefs().edit().putBoolean(PREF_CONNECTED, false).apply()
        updateState()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_action", "toggle")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        const val PREFS_NAME = "vpn_tile_state"
        const val PREF_CONNECTED = "connected"
        const val PREF_CONFIG = "config"
        const val PREF_REMARK = "remark"
        const val PREF_BLOCKED_APPS = "blocked_apps"
    }
}
