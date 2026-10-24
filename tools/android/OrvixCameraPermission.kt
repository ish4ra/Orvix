package com.orvix.orvix

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Camera permission state for the phone's "Scan TV QR" screen.
 *
 * mobile_scanner can request the permission itself but cannot tell a first
 * request from a permanent denial, and cannot open the app's settings. This
 * channel reports one of: granted, notRequested, denied (Android will ask
 * again), permanentlyDenied (Android will not ask again) or noCamera.
 */
class OrvixCameraPermissionChannel(
    private val activity: Activity,
    messenger: BinaryMessenger
) {
    companion object {
        // Requests from a FlutterActivity must fit in 16 bits; distinct from
        // mobile_scanner's own request code (0x0786).
        const val REQUEST_CODE = 0x4F52
        private const val PREFS = "orvix_camera_permission"
        private const val ASKED = "asked"
    }

    private val channel = MethodChannel(messenger, "orvix/camera_permission")
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "request" -> request(result)
                "openSettings" -> result.success(openSettings())
                else -> result.notImplemented()
            }
        }
    }

    private fun hasCamera(): Boolean =
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

    private fun granted(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun askedBefore(): Boolean =
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(ASKED, false)

    private fun status(): String = when {
        !hasCamera() -> "noCamera"
        granted() -> "granted"
        !askedBefore() -> "notRequested"
        ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.CAMERA
        ) -> "denied"
        else -> "permanentlyDenied"
    }

    private fun request(result: MethodChannel.Result) {
        if (!hasCamera() || granted()) {
            result.success(status())
            return
        }
        if (pending != null) {
            result.error("request_in_progress", "Camera permission request already open", null)
            return
        }
        pending = result
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ASKED, true)
            .apply()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CODE
        )
    }

    /** Returns true when the result belonged to this channel. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        result.success(status())
        return true
    }

    private fun openSettings(): Boolean = try {
        activity.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null)
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (_: Throwable) {
        false
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pending?.success(status())
        pending = null
    }
}
