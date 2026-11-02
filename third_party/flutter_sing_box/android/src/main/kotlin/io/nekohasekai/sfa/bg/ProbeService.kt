package io.nekohasekai.sfa.bg

import android.app.Service
import android.content.Intent
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.clashsing.flutter_sing_box.cs.PluginManager
import com.tencent.mmkv.MMKV
import io.nekohasekai.libbox.Notification

/**
 * Dedicated local proxy used to verify candidate nodes. It must remain a
 * separate Android service from the user's active VPN/proxy service so a
 * probe cannot replace the live connection's configuration.
 */
class ProbeService :
    Service(),
    PlatformInterfaceWrapper {
    companion object {
        const val CONFIG_PATH_EXTRA = "probe_config_path"
    }

    private lateinit var service: BoxService

    override fun onCreate() {
        super.onCreate()
        MMKV.initialize(applicationContext)
        PluginManager.init(applicationContext, "probe")
        service = BoxService(this, this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        service.configPath = intent?.getStringExtra(CONFIG_PATH_EXTRA)
        return service.onStartCommand()
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val network = PluginManager.connectivity.allNetworks.firstOrNull { candidate ->
            val capabilities = PluginManager.connectivity.getNetworkCapabilities(candidate)
                ?: return@firstOrNull false
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
        } ?: return
        runCatching {
            // fromFd duplicates the descriptor, so closing the wrapper does
            // not close libbox's socket.
            ParcelFileDescriptor.fromFd(fd).use { descriptor ->
                network.bindSocket(descriptor.fileDescriptor)
            }
        }
    }

    override fun onBind(intent: Intent): IBinder = service.onBind()

    override fun onDestroy() {
        if (::service.isInitialized) {
            service.serviceStop()
            service.onDestroy()
        }
        super.onDestroy()
    }

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)
}
