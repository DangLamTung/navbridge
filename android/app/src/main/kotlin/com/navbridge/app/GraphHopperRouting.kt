package com.navbridge.app

import com.graphhopper.GHRequest
import com.graphhopper.GraphHopper
import com.graphhopper.ResponsePath
import com.graphhopper.config.Profile
import com.graphhopper.json.Statement
import com.graphhopper.util.CustomModel
import com.graphhopper.util.shapes.GHPoint
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * On-device offline routing with GraphHopper (MIT).
 *
 * Loads a pre-built car graph (a folder extracted from a .ghz download) and
 * answers route requests over the "navbridge/routing" MethodChannel. All work
 * runs on a single background thread so the UI never blocks.
 */
class GraphHopperRouting {
    private var hopper: GraphHopper? = null
    private val executor = Executors.newSingleThreadExecutor()

    fun isLoaded(): Boolean = hopper != null

    /** The car profile used at graph build time — must match the builder. */
    private fun carProfile(): Profile {
        val cm = CustomModel()
            .addToPriority(Statement.If("!car_access", Statement.Op.MULTIPLY, "0"))
            .addToSpeed(Statement.If("true", Statement.Op.LIMIT, "car_average_speed"))
        return Profile("car").setCustomModel(cm)
    }

    /** Load a pre-built graph folder (or a `.ghz` zip) at [graphPath]. */
    fun load(graphPath: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                if (hopper == null) {
                    val gh = GraphHopper()
                    val loc = prepareLocation(graphPath)
                    gh.setGraphHopperLocation(loc)
                    gh.setEncodedValuesString("car_access, car_average_speed")
                    gh.setProfiles(carProfile())
                    gh.importOrLoad()
                    hopper = gh
                }
                result.success(true)
            } catch (e: Exception) {
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
                result.success(toJson(rsp.best))
            } catch (e: Exception) {
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

    private fun toJson(path: ResponsePath): JSONObject {
        val obj = JSONObject()
        obj.put("distance", path.distance)
        obj.put("duration", path.time / 1000.0)
        val pts = JSONArray()
        for (i in 0 until path.points.size()) {
            pts.put(path.points.getLat(i))
            pts.put(path.points.getLon(i))
        }
        obj.put("points", pts)
        val steps = JSONArray()
        for (ins in path.instructions) {
            val s = JSONObject()
            s.put("name", ins.name)
            s.put("distance", ins.distance)
            s.put("duration", ins.time / 1000.0)
            s.put("sign", ins.sign)
            val lat = if (ins.points.size() > 0) ins.points.getLat(0) else 0.0
            val lng = if (ins.points.size() > 0) ins.points.getLon(0) else 0.0
            s.put("lat", lat)
            s.put("lng", lng)
            steps.put(s)
        }
        obj.put("steps", steps)
        return obj
    }
}
