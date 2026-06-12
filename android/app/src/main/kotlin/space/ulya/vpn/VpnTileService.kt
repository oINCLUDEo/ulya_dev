package space.ulya.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile: shows whether a VPN is active and opens the app with
 * a `toggle` launch action on tap — the Dart side connects/disconnects the
 * selected server as soon as it boots.
 *
 * The tile deliberately does NOT start the VPN itself: building the xray
 * config requires the Dart layer (subscription parsing, split-tunneling
 * settings), so the honest contract is "one tap → app opens and toggles".
 */
class VpnTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateState()
    }

    private fun updateState() {
        val tile = qsTile ?: return
        tile.state = if (isVpnActive()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        tile.updateTile()
    }

    private fun isVpnActive(): Boolean {
        return try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.allNetworks.any { network ->
                cm.getNetworkCapabilities(network)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
        } catch (e: Exception) {
            false
        }
    }

    override fun onClick() {
        super.onClick()
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
}
