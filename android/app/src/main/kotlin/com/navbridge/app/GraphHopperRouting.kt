package com.navbridge.app

import com.graphhopper.GHRequest
import com.graphhopper.GraphHopper
import com.graphhopper.GraphHopperConfig
import com.graphhopper.ResponsePath
import com.graphhopper.config.Profile
import com.graphhopper.routing.ev.EnumEncodedValue
import com.graphhopper.routing.ev.IntEncodedValue
import com.graphhopper.routing.ev.RoadClass
import com.graphhopper.routing.util.EdgeFilter
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
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, msg: String?, details: Any? = null) {
        mainHandler.post { result.error(code, msg, details) }
    }

    fun isLoaded(): Boolean = hopper != null

    /** The car profile used at graph build time — must match the builder. */
    private fun carProfile(): Profile =
        Profile("car").setVehicle("car").setWeighting("fastest")

    /** Load a pre-built graph folder, or convert a `.ghz` zip / `.osm.pbf` on-device at [graphPath]. */
    fun load(graphPath: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                // If a graph was already loaded, close it first so the new file is actually loaded
                try {
                    hopper?.close()
                } catch (_: Throwable) {}
                hopper = null

                val f = java.io.File(graphPath)
                if (!f.exists()) throw IllegalStateException("Không tìm thấy dữ liệu: $graphPath")

                val isPbf = f.isFile && (f.name.endsWith(".pbf", ignoreCase = true) ||
                                        f.name.endsWith(".osm", ignoreCase = true))
                val loc = prepareLocation(graphPath)
                val destDir = java.io.File(loc)

                val gh = GraphHopper()
                val config = GraphHopperConfig()
                config.putObject("graph.dataaccess", "MMAP")
                config.putObject("graph.location", loc)
                config.putObject("import.osm.ignored_highways", "")
                config.putObject("graph.vehicles", "car")
                config.putObject("graph.encoded_values", "")
                config.setProfiles(listOf(carProfile()))

                if (isPbf) {
                    android.util.Log.i("NavBridgeRouter", "Converting OSM on device: ${f.absolutePath} -> $loc...")
                    // If destDir existed from an older/different graph, delete it so GraphHopper
                    // actually runs import rather than skipping it with load()
                    if (destDir.exists()) {
                        destDir.deleteRecursively()
                    }
                    gh.setOSMFile(f.absolutePath)
                }

                gh.init(config)
                gh.importOrLoad()

                // Once conversion on the phone completes, delete the downloaded PBF to free phone storage
                if (isPbf && f.exists() && f.absolutePath != destDir.absolutePath) {
                    try {
                        f.delete()
                        android.util.Log.i("NavBridgeRouter", "OSM graph converted on device; deleted download ${f.name}")
                    } catch (e: Throwable) {
                        android.util.Log.w("NavBridgeRouter", "Could not delete ${f.name}", e)
                    }
                }

                hopper = gh
                postSuccess(result, true)
            } catch (e: Throwable) {
                // Catch Errors too (e.g. NoSuchMethodError) so the app never
                // crashes from a graph problem.
                android.util.Log.e("NavBridgeRouter", "load failed", e)
                postError(result, "load_error", e.message ?: "load failed")
            }
        }
    }

    /** Unload the routing engine and release open file descriptors. */
    fun unload(result: MethodChannel.Result? = null) {
        executor.execute {
            try {
                hopper?.close()
            } catch (_: Throwable) {}
            hopper = null
            if (result != null) postSuccess(result, true)
        }
    }

    /**
     * Route through [points] (each a [GHPoint]). Returns a LIST of route maps
     * (best first) — [maxPaths] > 1 requests tap-to-choose alternatives
     * (`alternative_route.max_paths`). [avoidMotorway]/[avoidFerry] are
     * accepted but NOT applied here: the GraphHopper core 7.0 jar does not
     * expose the custom-model classes (they live in graphhopper-web-api,
     * which conflicts with core), and the public OSRM server rejects
     * `exclude=` — so road-class avoidance is only honored by OSRM servers
     * that support it (see the Dart `osrmExclude` best-effort retry).
     */
    fun route(
        points: List<GHPoint>,
        maxPaths: Int,
        avoidMotorway: Boolean,
        avoidFerry: Boolean,
        heading: Double?,
        result: MethodChannel.Result
    ) {
        executor.execute {
            try {
                val gh = hopper
                    ?: throw IllegalStateException("Chưa tải bộ dữ liệu chỉ đường")
                val req = GHRequest()
                for (p in points) req.addPoint(p)
                req.setProfile("car")
                // Depart along the car's travel heading so an off-route
                // reroute continues forward instead of U-turning back onto the
                // original road (Google-Maps-style "find the next good road").
                // Heading only applies on the flex (Dijkstra) algorithm — a
                // CH-prepared graph ignores it — so disable CH when set.
                if (heading != null) {
                    val h = heading % 360.0
                    if (GHRequest.isAzimuthValue(h)) {
                        val headings = ArrayList<Double>()
                        headings.add(h)
                        for (i in 1 until points.size) headings.add(Double.NaN)
                        req.setHeadings(headings)
                        req.putHint("ch.disable", true)
                    }
                }
                if (maxPaths > 1) {
                    req.putHint("alternative_route.max_paths", maxPaths)
                    req.putHint("alternative_route.max_weight_factor", 3)
                    req.putHint("alternative_route.max_share_factor", 0.8)
                    // AlternativeRoute runs on the flex (Dijkstra) algorithm —
                    // a CH-prepared graph silently returns 1 path otherwise.
                    req.putHint("ch.disable", true)
                }
                var rsp = gh.route(req)
                // Some algorithms/weights don't support alternatives — fall
                // back to the single best route rather than failing.
                if (rsp.hasErrors() && maxPaths > 1) {
                    val plain = GHRequest()
                    for (p in points) plain.addPoint(p)
                    plain.setProfile("car")
                    rsp = gh.route(plain)
                }
                if (rsp.hasErrors()) {
                    throw IllegalStateException(rsp.errors.toString())
                }
                android.util.Log.i(
                    "NavBridgeRouter",
                    "route: paths=${rsp.all.size} maxPaths=$maxPaths"
                )
                // Flutter's StandardMethodCodec only accepts primitives /
                // List / Map — NOT JSONObject. Send a plain list of maps.
                val out = ArrayList<Map<String, Any?>>()
                for (path in rsp.all) out.add(toMap(path))
                postSuccess(result, out)
            } catch (e: Throwable) {
                postError(result, "route_error", e.message ?: "route failed")
            }
        }
    }

    /** Road info (name / road class / maxspeed) at [lat],[lng] from the
     *  on-device graph — instant and offline (no Overpass round-trip).
     *  maxspeed is 0/absent when not tagged (Vietnam rarely tags it; the
     *  Dart side applies statutory defaults per road class). */
    fun roadInfo(lat: Double, lng: Double, result: MethodChannel.Result) {
        executor.execute {
            try {
                val gh = hopper
                    ?: throw IllegalStateException("Chưa tải bộ dữ liệu")
                val em = gh.encodingManager
                @Suppress("UNCHECKED_CAST")
                val roadClass = em.getEncodedValue(
                    "road_class", EnumEncodedValue::class.java
                ) as EnumEncodedValue<RoadClass>
                // GraphHopper 7.x stores max_speed as a DecimalEncodedValue in
                // km/h; older graphs/tooling exposed it as an IntEncodedValue.
                // Reading the WRONG registry yields garbage (e.g. a 50 km/h
                // limit showing as 31). Try the decimal registry first, then
                // fall back to the int one.
                val maxSpeedDec = try {
                    em.getDecimalEncodedValue("max_speed")
                } catch (_: Exception) {
                    null
                }
                val maxSpeedInt = try {
                    em.getIntEncodedValue("max_speed")
                } catch (_: Exception) {
                    null
                }
                val snap = gh.locationIndex.findClosest(lat, lng, EdgeFilter.ALL_EDGES)
                if (snap == null || !snap.isValid) {
                    postSuccess(result, null)
                    return@execute
                }
                val edge = snap.closestEdge
                val ms = when {
                    maxSpeedDec != null -> edge.get(maxSpeedDec)
                    maxSpeedInt != null -> edge.get(maxSpeedInt).toDouble()
                    else -> 0.0
                }
                val out = HashMap<String, Any?>()
                out["name"] = edge.name ?: ""
                out["highway"] = edge.get(roadClass)?.name?.lowercase() ?: ""
                // One-way flag — the VN built-up speed limit (Thông tư
                // 38/2024/TT-BGTVT) splits "đường đôi / đường một chiều có từ
                // hai làn xe cơ giới" (60) from "đường hai chiều / một làn"
                // (50), and OSM has NO median tag in Vietnam (0 of 9,011
                // highway ways sampled in HCMC/Đà Nẵng carry one), so `oneway`
                // is the only usable signal. Read it defensively: a graph built
                // without the encoded value must not break road info — the Dart
                // side treats a missing value as "unknown".
                var oneway: String? = null
                try {
                    if (em.hasEncodedValue("oneway")) {
                        val ow = em.getBooleanEncodedValue("oneway")
                        oneway = if (edge.get(ow)) "yes" else "no"
                    }
                } catch (_: Throwable) {
                    oneway = null
                }
                out["oneway"] = oneway
                // GraphHopper's default encodings carry no `lanes`; the Dart
                // side then treats a one-way street as >= 2 lanes (a one-way
                // through street), which is what the rule keys on.
                out["lanes"] = null
                // GraphHopper encodes `maxspeed=none` (no posted limit) as
                // +Infinity — that means "no limit", so send null and let the
                // Dart side apply the statutory class default.
                out["maxspeed"] = if (ms.isFinite() && ms > 0) ms else null
                android.util.Log.i(
                    "NavBridgeRouter",
                    "roadInfo: name=${edge.name} highway=${out["highway"]} maxspeed=$ms oneway=$oneway"
                )
                postSuccess(result, out)
            } catch (e: Throwable) {
                postError(result, "road_info_error", e.message ?: "road info failed")
            }
        }
    }

    /** Nearest road edge + snapped point to [lat],[lng] (network matching, like
     *  Google Maps): returns {lat, lng, distance (m to the road), edge (id)}
     *  or null when no road is nearby. Used to (a) stick the puck to the road
     *  and (b) detect when the car is on a road that is NOT part of the route. */
    fun snapToRoad(lat: Double, lng: Double, result: MethodChannel.Result) {
        executor.execute {
            try {
                val gh = hopper
                    ?: throw IllegalStateException("Chưa tải bộ dữ liệu")
                val snap = gh.locationIndex.findClosest(lat, lng, EdgeFilter.ALL_EDGES)
                if (snap == null || !snap.isValid) {
                    postSuccess(result, null)
                    return@execute
                }
                val sp = snap.snappedPoint
                val out = HashMap<String, Any?>()
                out["lat"] = sp.lat
                out["lng"] = sp.lon
                out["distance"] = snap.queryDistance
                out["edge"] = snap.closestEdge.edge
                android.util.Log.i(
                    "NavBridgeRouter",
                    "snap: d=${snap.queryDistance} edge=${snap.closestEdge.edge}"
                )
                postSuccess(result, out)
            } catch (e: Throwable) {
                postError(result, "snap_error", e.message ?: "snap failed")
            }
        }
    }

    /** If [graphPath] is a `.ghz` zip, extract it next to itself and return
     *  the extracted folder; if it is a `.pbf`, return the target folder;
     *  otherwise return the path unchanged. */
    private fun prepareLocation(graphPath: String): String {
        val f = java.io.File(graphPath)
        if (!f.exists()) throw IllegalStateException("Không tìm thấy dữ liệu: $graphPath")
        if (f.isDirectory) return f.absolutePath

        val isZip = f.name.endsWith(".ghz", ignoreCase = true) ||
                    f.name.endsWith(".zip", ignoreCase = true)

        val baseName = if (f.name.endsWith(".osm.pbf", ignoreCase = true)) {
            f.name.substring(0, f.name.length - 8)
        } else {
            f.nameWithoutExtension
        }
        val dest = java.io.File(f.parentFile, baseName)

        if (isZip) {
            if (dest.exists()) {
                android.util.Log.i("NavBridgeRouter", "Cleaning previous destination $dest...")
                dest.deleteRecursively()
            }
            android.util.Log.i("NavBridgeRouter", "Extracting $f -> $dest...")
            dest.mkdirs()
            java.util.zip.ZipFile(f).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val e = entries.nextElement()
                    // Zip-slip guard: reject entries that traverse outside the
                    // target directory (a malicious/corrupted archive must not
                    // write arbitrary files on the device).
                    if (e.name.contains("..")) {
                        android.util.Log.w("NavBridgeRouter", "Skipping suspicious archive entry: ${e.name}")
                        continue
                    }
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
            // Auto-delete the downloaded zip/ghz archive after extraction!
            try {
                if (dest.exists() && dest.list()?.isNotEmpty() == true) {
                    f.delete()
                    android.util.Log.i("NavBridgeRouter", "Converted archive on device; deleted download archive ${f.name}")
                }
            } catch (e: Throwable) {
                android.util.Log.w("NavBridgeRouter", "Could not delete archive ${f.name}", e)
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
        // GraphHopper 7.0 ResponsePath exposes no edge ids; on/off-route is
        // decided on the Dart side by snapping the fix and measuring the
        // snapped point's distance to this polyline.
        return mapOf(
            "distance" to path.distance,
            "duration" to (path.time / 1000.0),
            "points" to pts,
            "steps" to steps
        )
    }
}
