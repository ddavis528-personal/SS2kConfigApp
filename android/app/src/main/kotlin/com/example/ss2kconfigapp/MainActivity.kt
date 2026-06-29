package com.example.ss2kconfigapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
	private val powerChannelName = "com.example.ss2kconfigapp/power"
	private val networkChannelName = "com.example.ss2kconfigapp/network"
	private var multicastLock: WifiManager.MulticastLock? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, powerChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"isIgnoringBatteryOptimizations" -> {
						result.success(isIgnoringBatteryOptimizations())
					}
					"requestIgnoreBatteryOptimizations" -> {
						requestIgnoreBatteryOptimizations()
						result.success(true)
					}
					else -> result.notImplemented()
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"acquireMulticastLock" -> {
						acquireMulticastLock()
						result.success(true)
					}
					"releaseMulticastLock" -> {
						releaseMulticastLock()
						result.success(true)
					}
					else -> result.notImplemented()
				}
			}
	}

	// Without this, Android's WiFi power-save mode can silently drop incoming
	// mDNS reply packets while resolving the device's ".local" hostname.
	private fun acquireMulticastLock() {
		if (multicastLock?.isHeld == true) {
			return
		}
		val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
		val lock = wifiManager.createMulticastLock("ss2kMdnsLock")
		lock.setReferenceCounted(true)
		lock.acquire()
		multicastLock = lock
	}

	private fun releaseMulticastLock() {
		multicastLock?.let {
			if (it.isHeld) {
				it.release()
			}
		}
		multicastLock = null
	}

	private fun isIgnoringBatteryOptimizations(): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
			return true
		}

		val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
		return powerManager.isIgnoringBatteryOptimizations(packageName)
	}

	private fun requestIgnoreBatteryOptimizations() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) {
			return
		}

		val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
			data = Uri.parse("package:$packageName")
		}
		startActivity(intent)
	}
}
