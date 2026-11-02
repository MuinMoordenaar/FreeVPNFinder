package com.freevpnfinder

import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.clashsing.flutter_sing_box.cs.PluginManager
import com.clashsing.flutter_sing_box.utils.SettingsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.tencent.mmkv.MMKV
import io.nekohasekai.sfa.aidl.IService
import io.nekohasekai.sfa.aidl.IServiceCallback
import io.nekohasekai.sfa.bg.BoxService
import io.nekohasekai.sfa.bg.ProbeService
import io.nekohasekai.sfa.bg.ProxyService
import io.nekohasekai.sfa.constant.Action
import java.io.File
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "free_vpn_finder/android"
        private const val VPN_REQUEST_CODE = 2001
    }

    private var pendingVpnResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        MMKV.initialize(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handleMethod(call, result) }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startNormalService" -> {
                try {
                    PluginManager.init(applicationContext)
                    BoxService.start()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("SERVICE_START_FAILED", error.message, null)
                }
            }
            "startProbeService" -> {
                try {
                    PluginManager.init(applicationContext)
                    BoxService.startProbe(call.argument<String>("configPath"))
                    result.success(null)
                } catch (error: Exception) {
                    result.error("PROBE_START_FAILED", error.message, null)
                }
            }
            "startVpnService" -> startVpnService(result)
            "stopService" -> stopService(result)
            "stopProbeService" -> {
                try {
                    PluginManager.init(applicationContext)
                    BoxService.stopProbe()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("PROBE_STOP_FAILED", error.message, null)
                }
            }
            "waitForServiceState" -> waitForServiceState(call, result)
            "getServiceState" -> getServiceState(result)
            "getMmkvRoot" -> result.success(File(filesDir, "mmkv").absolutePath)
            "configureAndroidService" -> configureAndroidService(call, result)
            "listApplications" -> result.success(listApplications())
            else -> result.notImplemented()
        }
    }

    private fun startVpnService(result: MethodChannel.Result) {
        try {
            PluginManager.init(applicationContext)
            val permissionIntent = VpnService.prepare(this)
            if (permissionIntent != null) {
                pendingVpnResult = result
                startActivityForResult(permissionIntent, VPN_REQUEST_CODE)
            } else {
                BoxService.start()
                result.success(null)
            }
        } catch (error: Exception) {
            result.error("VPN_START_FAILED", error.message, null)
        }
    }

    private fun stopService(result: MethodChannel.Result) {
        try {
            PluginManager.init(applicationContext)
            BoxService.stop()
            result.success(null)
        } catch (error: Exception) {
            result.error("SERVICE_STOP_FAILED", error.message, null)
        }
    }

    private fun waitForServiceState(call: MethodCall, result: MethodChannel.Result) {
        val target = call.argument<String>("target") ?: "stopped"
        if (target != "started" && target != "stopped") {
            result.error("INVALID_SERVICE_STATE", "Unknown service state: $target", null)
            return
        }

        try {
            PluginManager.init(applicationContext)
        } catch (error: Exception) {
            result.error("SERVICE_STATE_FAILED", error.message, null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var finished = false
        var sawStarting = false
        var connection: ServiceConnection? = null
        var service: IService? = null
        var callback: IServiceCallback? = null

        fun finish(success: Boolean) {
            if (finished) return
            finished = true
            handler.removeCallbacksAndMessages(null)
            callback?.let {
                try {
                    service?.unregisterCallback(it)
                } catch (_: Exception) {
                }
            }
            connection?.let {
                try {
                    unbindService(it)
                } catch (_: Exception) {
                }
            }
            result.success(success)
        }

        fun handleStatus(status: Int) {
            val state = when (status) {
                0 -> "stopped"
                1 -> "starting"
                2 -> "started"
                3 -> "stopping"
                else -> "unknown"
            }
            if (state == "starting") sawStarting = true
            if (state == target) {
                finish(true)
            } else if (target == "started" && state == "stopped" && sawStarting) {
                finish(false)
            }
        }

        callback = object : IServiceCallback.Stub() {
            override fun onServiceStatusChanged(status: Int) {
                runOnUiThread { handleStatus(status) }
            }

            override fun onServiceAlert(type: Int, message: String?) {
                runOnUiThread { finish(false) }
            }
        }

        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                try {
                    service = IService.Stub.asInterface(binder)
                    service?.registerCallback(callback)
                    handleStatus(service?.status ?: 0)
                } catch (_: Exception) {
                    finish(false)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                finish(target == "stopped")
            }

            override fun onBindingDied(name: ComponentName?) {
                finish(target == "stopped")
            }
        }

        handler.postDelayed(
            { finish(target == "stopped") },
            if (target == "started") 12_000 else 3_000,
        )
        // A newly started service can still report its initial Stopped state
        // while onStartCommand is being delivered. Give it a short grace
        // period before treating that initial state as a failed start.
        if (target == "started") {
            handler.postDelayed(
                { if (!finished && !sawStarting) finish(false) },
                10_000,
            )
        }
        val serviceClass = if (call.argument<String>("service") == "probe") {
            ProbeService::class.java
        } else {
            SettingsManager.serviceClass()
        }
        val intent = Intent(this, serviceClass).setAction(Action.SERVICE)
        try {
            val bindFlags = if (target == "started") BIND_AUTO_CREATE else 0
            if (!bindService(intent, connection!!, bindFlags)) {
                finish(target == "stopped")
            }
        } catch (_: Exception) {
            finish(target == "stopped")
        }
    }

    private fun getServiceState(result: MethodChannel.Result) {
        try {
            PluginManager.init(applicationContext)
        } catch (_: Exception) {
            result.success(0)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var finished = false
        var connection: ServiceConnection? = null

        fun finish(state: Int) {
            if (finished) return
            finished = true
            handler.removeCallbacksAndMessages(null)
            connection?.let {
                try {
                    unbindService(it)
                } catch (_: Exception) {
                }
            }
            result.success(state)
        }

        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val state = try {
                    IService.Stub.asInterface(binder)?.status ?: 0
                } catch (_: Exception) {
                    0
                }
                finish(state)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                finish(0)
            }

            override fun onBindingDied(name: ComponentName?) {
                finish(0)
            }
        }

        handler.postDelayed({ finish(0) }, 1_000)
        val intent = Intent(this, SettingsManager.serviceClass()).setAction(Action.SERVICE)
        try {
            if (!bindService(intent, connection!!, 0)) finish(0)
        } catch (_: Exception) {
            finish(0)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return
        val result = pendingVpnResult
        pendingVpnResult = null
        if (result == null) return
        if (resultCode == RESULT_OK) {
            try {
                PluginManager.init(applicationContext)
                BoxService.start()
                result.success(null)
            } catch (error: Exception) {
                result.error("VPN_START_FAILED", error.message, null)
            }
        } else {
            result.error("VPN_PERMISSION_DENIED", "VPN permission denied", null)
        }
    }

    private fun configureAndroidService(call: MethodCall, result: MethodChannel.Result) {
        val serviceMode = call.argument<String>("serviceMode") ?: "vpn"
        val perAppMode = call.argument<String>("perAppMode") ?: "disabled"
        val packages = call.argument<List<String>>("packages") ?: emptyList()
        if (serviceMode == "probe") {
            // Probes run in their own process and must not rewrite settings
            // used by the live VPN service.
            result.success(null)
            return
        }
        MMKV.initialize(applicationContext)
        val settings = MMKV.mmkvWithID("cs_settings", MMKV.MULTI_PROCESS_MODE)
        if (serviceMode != "probe") settings.encode("service_mode", serviceMode)
        settings.encode(
            "per_app_proxy_mode",
            when (perAppMode) {
                "vpnOnly" -> 1
                "bypass" -> 2
                else -> 0
            },
        )
        val packageJson = JSONArray(packages).toString()
        settings.encode(
            "per_app_proxy_include_list",
            if (perAppMode == "vpnOnly") packageJson else "[]",
        )
        settings.encode(
            "per_app_proxy_exclude_list",
            if (perAppMode == "bypass") packageJson else "[]",
        )
        result.success(null)
    }

    private fun listApplications(): List<Map<String, String>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        return packageManager.queryIntentActivities(launcherIntent, PackageManager.MATCH_ALL)
            .map { info ->
                mapOf(
                    "packageName" to info.activityInfo.packageName,
                    "label" to info.loadLabel(packageManager).toString(),
                )
            }
            .distinctBy { it["packageName"] }
            .sortedBy { it["label"]?.lowercase() }
    }
}
