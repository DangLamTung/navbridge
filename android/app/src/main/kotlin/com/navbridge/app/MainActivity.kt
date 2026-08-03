package com.navbridge.app

import android.os.Bundle
import com.graphhopper.util.shapes.GHPoint
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val routing = GraphHopperRouting()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        routing.route(points, result)
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
}
