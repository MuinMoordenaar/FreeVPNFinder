package com.clashsing.flutter_sing_box.cs

import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import io.nekohasekai.sfa.constant.Bugs
import com.clashsing.flutter_sing_box.utils.ProfileManager
import com.clashsing.flutter_sing_box.utils.SettingsManager
import com.tencent.mmkv.MMKV
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

object PluginManager {
    @Volatile
    private var _appContext: Context? =  null
    val appContext: Context get() = _appContext ?: throw throwError()

    fun init(context: Context, instanceName: String? = null) {
        val checkedResult = _appContext
        if (checkedResult != null) {
            return
        }
        synchronized(this) {
            val doubleCheckedResult = _appContext
            if (doubleCheckedResult != null) {
                return
            }
            this._appContext = context.applicationContext
            MMKV.mmkvWithID(ProfileManager.MMKV_ID, MMKV.MULTI_PROCESS_MODE)
            MMKV.mmkvWithID(SettingsManager.MMKV_ID, MMKV.MULTI_PROCESS_MODE)
            initSingBox(instanceName)
        }
    }

    private fun initSingBox(instanceName: String? = null) {
//        Seq.setContext(appContext)
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        val suffix = instanceName?.takeIf { it.isNotBlank() }
        val baseDir = suffix?.let { File(appContext.filesDir, it) } ?: appContext.filesDir
        baseDir.mkdirs()
        val externalFilesDir = appContext.getExternalFilesDir(null) ?: return
        val workingDir = suffix?.let { File(externalFilesDir, it) } ?: externalFilesDir
        workingDir.mkdirs()
        val tempDir = suffix?.let { File(appContext.cacheDir, it) } ?: appContext.cacheDir
        tempDir.mkdirs()
        Libbox.setup(SetupOptions().also {
            it.basePath = baseDir.path
            it.workingPath = workingDir.path
            it.tempPath = tempDir.path
            it.fixAndroidStack = Bugs.fixAndroidStack
            it.logMaxLines = 3000
            it.debug = false // TODO: 临时赋值 false
        })
        val stderrName = suffix?.let { "stderr-$it.log" } ?: "stderr.log"
        Libbox.redirectStderr(File(workingDir, stderrName).path)
    }

    val connectivity by lazy { appContext.getSystemService<ConnectivityManager>() ?: throw throwError() }

    val packageManager by lazy { appContext.packageManager ?: throw throwError() }

    val wifiManager by lazy { appContext.getSystemService<WifiManager>() ?: throw throwError() }

    val notification by lazy { appContext.getSystemService<NotificationManager>() ?: throw throwError() }

    val launchIntent by lazy {
        packageManager.getLaunchIntentForPackage(appContext.packageName) ?: throw throwError()
    }

    val powerManager by lazy { appContext.getSystemService<PowerManager>() ?: throw throwError() }

    private fun throwError() : Throwable = IllegalStateException(
        "PluginManager not initialized. Call PluginManager.init() first."
    )

}
