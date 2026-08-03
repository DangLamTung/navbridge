package com.navbridge.app

import com.graphhopper.GHRequest
import com.graphhopper.GraphHopper
import com.graphhopper.GraphHopperConfig
import com.graphhopper.ResponsePath
import com.graphhopper.config.Profile
import com.graphhopper.util.shapes.GHPoint
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * On-device offline routing with GraphHopper (MIT).
 *
 * Loads a pre-built car graph (a folder extracted from a .ghz download) and
 * answers route requests over the "navbridge/routing" MethodChannel. All work
 * runs on a single background thread so the UI never blocks.
 *
 * GraphHopper 7.0 is used on purpose: it is the last line with the classic
 * setVehicle/setWeighting("fastest") profiles — newer lines need custom models
 * (Janino dynamic compilation) which does not work on Android ART.
 */
class GraphHopperRouting {
    private var hopper: GraphHopper? = null
    private val executor = Executors.newSingleThreadExecutor()

    fun isLoaded(): Boolean = hopper != null

    /** The car profile used at graph build time — must match the builder. */
    private fun carProfile(): Profile =
        Profile("car").setVehicle("car").setWeighting("fastest")

    /** Load a pre-built graph folder (or a `.ghz` zip) at [graphPath]. */
    fun load(graphPath: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                if (hopper == null) {
                    val gh = GraphHopper()
                    val loc = prepareLocation(graphPath)
                    // MMAP data access: maps graph files lazily instead of
                    // loading them into the Java heap. Needed for the
                    // whole-Vietnam graph (~450 MB) on phone-size heaps.
                    val config = GraphHopperConfig()
                    config.putObject("graph.dataaccess", "MMAP")
                    config.putObject("graph.location", loc)
                    // init() hard-requires these keys even for pure loading.
                    config.putObject("import.osm.ignored_highways", "")
                    config.putObject("graph.vehicles", "car")
                    config.putObject("graph.encoded_values", "")
                    config.setProfiles(listOf(carProfile()))
                    gh.init(config)
                    gh.importOrLoad()
                    hopper = gh
                }
                result.success(true)
            } catch (e: Throwable) {
                // Catch Errors too (e.g. NoSuchMethodError) so the app never
                // crashes from a graph problem.
                android.util.Log.e("NavBridgeRouter", "load failed", e)
                result.error("load_error", e.message ?: "load failed", null)
            }
        }
    }

    /** Route through [points] (each a [GHPoint]); returns a JSON route. */
    fun route(points: List<GHPoint>, result: MethodChannel.Result) {
        executor.execute {
            try {
                val gh = hopper
                    ?: throw IllegalStateException("Chưa tải bộ dữ liệu chỉ đường")
                val req = GHRequest()
                for (p in points) req.addPoint(p)
                req.setProfile("car")
                val rsp = gh.route(req)
                if (rsp.hasErrors()) {
                    throw IllegalStateException(rsp.errors.toString())
                }
                // Flutter's StandardMethodCodec only accepts primitives /
                // List / Map — NOT JSONObject. Send a plain Map.
                result.success(toMap(rsp.best))
            } catch (e: Throwable) {
                result.error("route_error", e.message ?: "route failed", null)
            }
        }
    }

    /** If [graphPath] is a `.ghz` zip, extract it next to itself and return
     *  the extracted folder; otherwise return the path unchanged. */
    private fun prepareLocation(graphPath: String): String {
        val f = java.io.File(graphPath)
        if (!f.exists()) throw IllegalStateException("Không tìm thấy dữ liệu: $graphPath")
        if (f.isDirectory) return f.absolutePath
        val dest = java.io.File(f.parentFile, f.nameWithoutExtension)
        if (!dest.exists()) {
            java.util.zip.ZipFile(f).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val e = entries.nextElement()
                    val out = java.io.File(dest, e.name)
                    if (e.isDirectory) {
                        out.mkdirs()
                    } else {
                        out.parentFile?.mkdirs()
                        zip.getInputStream(e).use { input ->
                            out.outputStream().use { output -> input.copyTo(output) }
                        }
                    }
                }
            }
        }
        return dest.absolutePath
    }

    /** Builds a plain Map (MethodChannel-codec friendly) from the route. */
    private fun toMap(path: ResponsePath): Map<String, Any?> {
        val pts = ArrayList<Double>()
        for (i in 0 until path.points.size()) {
            pts.add(path.points.getLat(i))
            pts.add(path.points.getLon(i))
        }
        val steps = ArrayList<Map<String, Any?>>()
        for (ins in path.instructions) {
            steps.add(mapOf(
                "name" to ins.name,
                "distance" to ins.distance,
                "duration" to (ins.time / 1000.0),
                "sign" to ins.sign,
                "lat" to (if (ins.points.size() > 0) ins.points.getLat(0) else 0.0),
                "lng" to (if (ins.points.size() > 0) ins.points.getLon(0) else 0.0)
            ))
        }
        return mapOf(
            "distance" to path.distance,
            "duration" to (path.time / 1000.0),
            "points" to pts,
            "steps" to steps
        )
    }
}
