package com.navbridge.app

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Rational
import com.graphhopper.util.shapes.GHPoint
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val routing = GraphHopperRouting()
    private var pipChannel: MethodChannel? = null

    /// Google-Maps behavior: while navigating, pressing Home shrinks the app
    /// into a small PiP window instead of fully backgrounding. Set by the
    /// Flutter side on nav start/exit.
    private var autoEnterPip = false

    /// PiP window shape (see [pipAspect]). Updated live via `setAspect` so the
    /// window re-shapes even while it's open. Defaults to the larger 3:4.
    private var pipAspect: String = "34"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Picture-in-Picture (Part C of the background-nav plan).
        pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "navbridge/pip"
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPipSupported())
                    "isInPip" -> result.success(isInPictureInPictureMode)
                    "enter" -> {
                        pipAspect = call.argument<String>("aspect") ?: "portrait"
                        result.success(enterPip())
                    }
                    "setAspect" -> {
                        pipAspect = call.argument<String>("aspect") ?: "portrait"
                        updatePipParams()
                        result.success(null)
                    }
                    "setAutoEnter" -> {
                        autoEnterPip = call.argument<Boolean>("active") ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navbridge/routing")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> {
                        val dir = call.argument<String>("dir") ?: ""
                        routing.load(dir, result)
                    }
                    "route" -> {
                        val flat = call.argument<List<Double>>("points") ?: emptyList()
                        val points = flat.chunked(2).map { GHPoint(it[0], it[1]) }
                        val maxPaths = (call.argument<Int>("alternatives") ?: 1).coerceAtLeast(1)
                        val avoidMotorway = call.argument<Boolean>("avoidMotorway") ?: false
                        val avoidFerry = call.argument<Boolean>("avoidFerry") ?: false
                        routing.route(points, maxPaths, avoidMotorway, avoidFerry, result)
                    }
                    "isLoaded" -> result.success(routing.isLoaded())
                    "roadInfo" -> {
                        routing.roadInfo(
                            call.argument<Double>("lat") ?: 0.0,
                            call.argument<Double>("lng") ?: 0.0,
                            result,
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isPipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /// Aspect ratio for the requested [pipAspect] shape:
    ///   '34' 3:4 (default — larger, portrait-ish, easy to read)
    ///   'portrait' 9:16 · 'landscape' 4:3
    private fun pipRational(aspect: String): Rational = when (aspect) {
        "landscape" -> Rational(4, 3)
        "portrait" -> Rational(9, 16)
        "34" -> Rational(3, 4)
        else -> Rational(3, 4) // larger default
    }

    /// Re-shape the PiP window with the current [pipAspect]. Calling this
    /// while the window is open updates its shape live (Android supports
    /// calling setPictureInPictureParams repeatedly).
    private fun updatePipParams() {
        if (!isPipSupported() || !isInPictureInPictureMode) return
        try {
            setPictureInPictureParams(pipParams())
        } catch (_: Throwable) {
        }
    }

    /// PictureInPictureParams for the configured [pipAspect] shape. On API 31+
    /// also hints a LARGE source region (the whole screen) so the OS opens the
    /// PiP window as big as it allows — a small hint makes the floating window
    /// tiny, which is what made the map feel cramped.
    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(pipRational(pipAspect))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val dm = resources.displayMetrics
                b.setSourceRectHint(Rect(0, 0, dm.widthPixels, dm.heightPixels))
            } catch (_: Throwable) {
            }
        }
        return b.build()
    }

    /// Enter PiP with the configured [pipAspect] shape.
    private fun enterPip(): Boolean {
        if (!isPipSupported()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // API 31+: persist the params first, then enter — otherwise
                // some devices open the window with the OS default ratio.
                setPictureInPictureParams(pipParams())
            }
            enterPictureInPictureMode(pipParams())
        } catch (_: Throwable) {
            false
        }
    }

    /// Auto-enter PiP when the user leaves the app (Home / recents) during nav.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoEnterPip) enterPip()
    }

    /// Notify the Flutter side when PiP mode toggles so it can swap to the
    /// compact layout (or back to the full UI).
    private fun notifyPipChanged(active: Boolean) {
        pipChannel?.invokeMethod(
            "onPipChanged", mapOf("active" to active)
        )
    }

    // On API 31+ Activity's default onPictureInPictureModeChanged(UiState)
    // delegates to this 2-arg override, so overriding just this one catches
    // PiP entry/exit on every supported API level (26+).
    @Deprecated("Deprecated in Java")
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPipChanged(isInPictureInPictureMode)
        if (isInPictureInPictureMode) {
            // Re-assert our requested aspect on the first frame — some ROMs
            // (e.g. itel) open the window at the OS default ratio and ignore
            // the ratio passed to enterPictureInPictureMode.
            try {
                setPictureInPictureParams(pipParams())
            } catch (_: Throwable) {
            }
        }
    }
}
