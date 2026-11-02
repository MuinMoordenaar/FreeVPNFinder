package io.nekohasekai.sfa.bg

import android.app.Service
import android.content.Intent
import com.clashsing.flutter_sing_box.cs.PluginManager
import com.tencent.mmkv.MMKV
import io.nekohasekai.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private lateinit var service: BoxService

    override fun onCreate() {
        super.onCreate()
        MMKV.initialize(applicationContext)
        PluginManager.init(applicationContext)
        service = BoxService(this, this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand()

    override fun onBind(intent: Intent) = service.onBind()

    override fun onDestroy() {
        if (::service.isInitialized) {
            // stopService() is intentionally scoped to the probe process. The
            // direct stopService call otherwise skips BoxService cleanup and
            // can leave the native probe core alive after each batch.
            service.serviceStop()
            service.onDestroy()
        }
        super.onDestroy()
    }

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)
}
