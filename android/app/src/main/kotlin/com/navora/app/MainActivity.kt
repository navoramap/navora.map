package com.navora.app

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			"navora/google_places_client_identity",
		).setMethodCallHandler { call, result ->
			if (call.method != "getIdentity") {
				result.notImplemented()
				return@setMethodCallHandler
			}

			try {
				val certificateSha1 = signingCertificateSha1()
				if (certificateSha1 == null) {
					result.error(
						"SIGNATURE_UNAVAILABLE",
						"Android signing certificate is unavailable.",
						null,
					)
				} else {
					result.success(
						mapOf(
							"packageName" to applicationContext.packageName,
							"sha1" to certificateSha1,
						),
					)
				}
			} catch (error: Exception) {
				result.error("SIGNATURE_UNAVAILABLE", error.message, null)
			}
		}
	}

	@Suppress("DEPRECATION")
	private fun signingCertificateSha1(): String? {
		val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
			packageManager.getPackageInfo(
				applicationContext.packageName,
				PackageManager.GET_SIGNING_CERTIFICATES,
			)
		} else {
			packageManager.getPackageInfo(
				applicationContext.packageName,
				PackageManager.GET_SIGNATURES,
			)
		}
		val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
			packageInfo.signingInfo?.apkContentsSigners
		} else {
			packageInfo.signatures
		}
		val certificate = signatures?.firstOrNull() ?: return null

		return MessageDigest.getInstance("SHA-1")
			.digest(certificate.toByteArray())
			.joinToString("") { byte ->
				(byte.toInt() and 0xFF).toString(16).padStart(2, '0').uppercase()
			}
	}
}
