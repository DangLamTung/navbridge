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
import com.graphhopper.util.EdgeIteratorState
import com.graphhopper.util.FetchMode
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

    /** Context for [exportArchive] (MediaStore needs it), and the sink for
     *  [buildArchive] progress. Both are wired once by MainActivity when the
     *  "navbridge/routing" channel is registered. */
    private var appContext: android.content.Context? = null
    private var archiveProgress: ((Long, Long) -> Unit)? = null

    fun attach(context: android.content.Context, onArchiveProgress: (Long, Long) -> Unit) {
        appContext = context
        archiveProgress = onArchiveProgress
    }

    private fun postArchiveProgress(done: Long, total: Long) {
        val cb = archiveProgress ?: return
        mainHandler.post { cb(done, total) }
    }

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
                } else if (destDir.isDirectory && !graphMarkerPresent(destDir)) {
                    // A folder with no `GH` marker in `properties` is the debris of
                    // an interrupted import (the import creates that file first, so
                    // a killed process leaves it empty). GraphHopper would fail deep
                    // in its storage layer with "Not a GraphHopper file … Expected
                    // 'GH'" — a message the UI cannot act on. Refuse it here with a
                    // code the Offline screen turns into "delete and reload".
                    android.util.Log.e(
                        "NavBridgeRouter",
                        "refusing markerless graph folder: $loc"
                    )
                    postError(
                        result,
                        "graph_corrupt",
                        "Dữ liệu chỉ đường trên máy bị hỏng (bản nạp dở) — cần xoá và nạp lại",
                    )
                    return@execute
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
                // Say so out loud: a SUCCESSFUL load used to log nothing, so
                // "is the graph actually usable?" could only be answered by
                // inference from silence. One line makes it unambiguous.
                android.util.Log.i(
                    "NavBridgeRouter",
                    "graph loaded: ${gh.baseGraph.nodes} nodes, " +
                        "profile=${gh.profiles} from $graphPath"
                )
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
     * Zip the built graph folder into a portable `.ghz` archive — the exact
     * counterpart of [load]'s `.ghz` branch, and the same archive
     * `tools/build_graph.sh` produces on a PC.
     *
     * Why on the phone: importing the 311 MB country extract costs minutes of
     * CPU and GBs of RAM, and the same graph gets rebuilt from scratch after
     * every reinstall. Building it once and keeping the archive means another
     * handset only has to UNZIP it (see `prepareLocation`), and `adb pull` can
     * take the finished graph back to the PC.
     *
     * Streamed entry by entry with a 1 MB buffer: the ~450 MB graph folder must
     * never be held in memory on a low-end device. Progress is reported at most
     * ~100 times over the whole run, so the platform channel is not flooded.
     */
    fun buildArchive(dirPath: String, outPath: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val src = java.io.File(dirPath)
                if (!src.isDirectory) {
                    throw IllegalStateException("Không phải thư mục graph: $dirPath")
                }
                val files = src.walkTopDown().filter { it.isFile }.toList()
                if (files.isEmpty()) {
                    throw IllegalStateException("Thư mục graph rỗng: $dirPath")
                }
                val total = files.sumOf { it.length() }
                val out = java.io.File(outPath)
                out.parentFile?.mkdirs()
                var done = 0L
                var lastPing = 0L
                val step = (total / 100).coerceAtLeast(1L)
                java.util.zip.ZipOutputStream(
                    java.io.BufferedOutputStream(out.outputStream(), 1 shl 20)
                ).use { zip ->
                    for (f in files) {
                        // Relative entry names, so on-device extraction lands the
                        // graph files directly in the target folder.
                        val name = src.toURI().relativize(f.toURI()).path
                        zip.putNextEntry(java.util.zip.ZipEntry(name))
                        f.inputStream().use { it.copyTo(zip, 1 shl 20) }
                        zip.closeEntry()
                        done += f.length()
                        if (done - lastPing >= step) {
                            lastPing = done
                            postArchiveProgress(done, total)
                        }
                    }
                }
                postArchiveProgress(total, total)
                if (out.length() <= 0L) {
                    out.delete()
                    throw IllegalStateException("Tệp .ghz tạo ra rỗng")
                }
                android.util.Log.i(
                    "NavBridgeRouter",
                    "built archive ${out.name}: ${out.length()} bytes from $total bytes"
                )
                val res = HashMap<String, Any?>()
                res["path"] = out.absolutePath
                res["bytes"] = out.length()
                res["sourceBytes"] = total
                postSuccess(result, res)
            } catch (e: Throwable) {
                android.util.Log.e("NavBridgeRouter", "buildArchive failed", e)
                postError(result, "archive_error", e.message ?: "build archive failed")
            }
        }
    }

    /**
     * Copy a built `.ghz` into shared storage so it survives an uninstall and is
     * reachable by a file manager, another phone, or `adb pull`.
     *
     * API 29+ publishes it through MediaStore.Downloads, which an app may do for
     * its OWN file with no permission at all. API 26–28 has no Downloads
     * collection in MediaStore, so it writes the public Downloads folder — that
     * needs WRITE_EXTERNAL_STORAGE (declared with maxSdkVersion=28); when it is
     * not granted the call answers `need_permission` so the UI can ask and retry
     * rather than failing with a bare SecurityException.
     */
    fun exportArchive(srcPath: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val src = java.io.File(srcPath)
                if (!src.isFile) {
                    throw IllegalStateException("Không thấy tệp .ghz: $srcPath")
                }
                val name = src.name
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    val ctx = appContext
                        ?: throw IllegalStateException("Không có Context")
                    val values = android.content.ContentValues().apply {
                        put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                        put(
                            android.provider.MediaStore.MediaColumns.MIME_TYPE,
                            "application/zip"
                        )
                        put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Download")
                        put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                    val resolver = ctx.contentResolver
                    val uri = resolver.insert(
                        android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                    ) ?: throw IllegalStateException("MediaStore từ chối tạo tệp")
                    try {
                        val outStream = resolver.openOutputStream(uri)
                            ?: throw IllegalStateException("Không mở được đích Downloads")
                        outStream.use { o ->
                            src.inputStream().use { i -> i.copyTo(o, 1 shl 20) }
                        }
                        values.clear()
                        values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                        resolver.update(uri, values, null, null)
                    } catch (e: Throwable) {
                        try {
                            resolver.delete(uri, null, null)
                        } catch (_: Throwable) {}
                        throw e
                    }
                    postSuccess(result, "Download/$name")
                } else {
                    @Suppress("DEPRECATION")
                    val dir = android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_DOWNLOADS
                    )
                    if (!dir.exists() && !dir.mkdirs()) {
                        throw IllegalStateException("Không tạo được thư mục Downloads")
                    }
                    val dst = java.io.File(dir, name)
                    dst.outputStream().use { o ->
                        src.inputStream().use { i -> i.copyTo(o, 1 shl 20) }
                    }
                    postSuccess(result, dst.absolutePath)
                }
            } catch (e: SecurityException) {
                postError(result, "need_permission", "Cần quyền ghi bộ nhớ để xuất tệp")
            } catch (e: Throwable) {
                android.util.Log.e("NavBridgeRouter", "exportArchive failed", e)
                postError(result, "export_error", e.message ?: "export failed")
            }
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

    /** Axis bearing (0=N, clockwise) of an edge, or null when it can't be read.
     *  Uses THIS edge's own geometry (base pillar → adj node) — the direction of
     *  the road under the query point, not the whole way's overall heading. */
    private fun edgeAxisBearing(edge: EdgeIteratorState): Double? = try {
        val pl = edge.fetchWayGeometry(FetchMode.PILLAR_AND_ADJ)
        if (pl.size() < 2) null
        else bearingDeg(pl.getLat(0), pl.getLon(0), pl.getLat(1), pl.getLon(1))
    } catch (_: Throwable) {
        null
    }

    /** Smallest angle (0..90°) between the road's AXIS and [heading]. A road is
     *  an axis: 180° apart is the SAME street (a two-way road), so a car heading
     *  opposite its own travel direction is 0° off, not 180°. */
    private fun axisMisalignmentDeg(bearing: Double, heading: Double): Double {
        var d = Math.abs((bearing - heading) % 360.0)
        if (d > 180.0) d = 360.0 - d
        return Math.min(d, 180.0 - d)
    }

    private fun bearingDeg(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dl = Math.toRadians(lon2 - lon1)
        val y = Math.sin(dl) * Math.cos(p2)
        val x = Math.cos(p1) * Math.sin(p2) -
            Math.sin(p1) * Math.cos(p2) * Math.cos(dl)
        return (Math.toDegrees(Math.atan2(y, x)) + 360.0) % 360.0
    }

    /** Road info (name / road class / maxspeed) at [lat],[lng] from the
     *  on-device graph — instant and offline (no Overpass round-trip).
     *  maxspeed is 0/absent when not tagged (Vietnam rarely tags it; the
     *  Dart side applies statutory defaults per road class).
     *  [heading] (degrees, 0=N) lets the snap reject a CROSS street. */
    fun roadInfo(
        lat: Double,
        lng: Double,
        heading: Double?,
        result: MethodChannel.Result
    ) {
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
                // ⭐ HEADING-AWARE SNAP. `findClosest` returns the NEAREST edge,
                // which at a junction is frequently the CROSS street a few metres
                // away — the road name / limit then flashed to the wrong street
                // every time the car crossed one. When the car's travel heading
                // is known, reject an edge that runs ACROSS it and retry keeping
                // only roughly-parallel edges; fall back to the plain nearest
                // edge when that finds nothing (a U-turn / perpendicular start).
                var snap = gh.locationIndex.findClosest(lat, lng, EdgeFilter.ALL_EDGES)
                if (snap != null && snap.isValid && heading != null) {
                    val brg0 = edgeAxisBearing(snap.closestEdge)
                    if (brg0 != null && axisMisalignmentDeg(brg0, heading) > 60.0) {
                        val h = heading
                        val aligned = try {
                            gh.locationIndex.findClosest(
                                lat,
                                lng,
                                EdgeFilter { e ->
                                    val b = edgeAxisBearing(e)
                                    b == null || axisMisalignmentDeg(b, h) <= 60.0
                                }
                            )
                        } catch (_: Throwable) {
                            null
                        }
                        if (aligned != null && aligned.isValid) snap = aligned
                    }
                }
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
                // ⭐ PER-DIRECTION CAR ACCESS — the road FORM, and the reason the
                // app could not tell a đường đôi from a hai chiều street.
                //
                // The VN built-up limit (Thông tư 38/2024/TT-BGTVT) splits
                // "đường đôi / đường một chiều có từ hai làn xe cơ giới" (60)
                // from "đường hai chiều / một làn" (50), and OSM has NO median
                // tag in Vietnam (0 of 9,011 highway ways sampled in HCMC/Đà
                // Nẵng carry one). GraphHopper 7 has no `oneway` encoded value
                // either, so this always came back null and the Dart side read
                // EVERY street as "form unknown" — falling back to the zone
                // ceiling (60 in town) even on genuine two-way streets.
                //
                // The information IS in the graph: `car_access` is stored for
                // both directions, and a one-way way opens exactly one of them.
                // Mappers split a divided road into one way per carriageway, so
                // "one direction only" is precisely the đường-đôi signal.
                // Verified against the shipped graph with
                // `tools/ProbeOneway.java`:
                //   Lũy Bán Bích / Trường Chinh / Trần Quốc Hoàn  fwd=true  bwd=false
                //   Đường 30 Tháng 4 / Cách Mạng / Âu Cơ             fwd=true  bwd=true
                // The Dart side turns the pair into `oneway` (roadInfoFromGraph →
                // onewayFromCarAccess); it prefers an explicit `oneway` value if
                // a graph ever carries one. Read defensively: a graph without
                // the encoded value must not break road info.
                var carFwd: Boolean? = null
                var carBwd: Boolean? = null
                try {
                    val access = em.getBooleanEncodedValue("car_access")
                    if (access != null) {
                        carFwd = edge.get(access)
                        carBwd = edge.getReverse(access)
                    }
                } catch (_: Throwable) {
                    carFwd = null
                    carBwd = null
                }
                out["car_access_fwd"] = carFwd
                out["car_access_bwd"] = carBwd
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
                    "roadInfo: name=${edge.name} highway=${out["highway"]} " +
                        "maxspeed=$ms oneway=$oneway access=$carFwd/$carBwd"
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

    /**
     * Whether [dir] looks like a GraphHopper graph.
     *
     * GraphHopper writes the ASCII pair `GH` after a two-byte field — a real
     * `properties` starts `00 02 47 48`, so the marker is NOT at offset 0. The
     * first version of this check assumed offset 0 and therefore rejected a
     * folder it had just extracted itself, then failed on the (already deleted)
     * archive. The pair is searched in the first 8 bytes instead, and one level
     * down too, because a `.ghz` whose entries keep a wrapper directory extracts
     * to `dir/<wrapper>/properties`.
     */
    private fun graphMarkerPresent(dir: java.io.File): Boolean {
        if (hasGraphMarker(java.io.File(dir, "properties"))) return true
        return try {
            dir.listFiles()?.any {
                it.isDirectory && hasGraphMarker(java.io.File(it, "properties"))
            } == true
        } catch (_: Throwable) {
            false
        }
    }

    private fun hasGraphMarker(props: java.io.File): Boolean {
        if (!props.isFile) return false
        return try {
            props.inputStream().use { i ->
                val head = ByteArray(8)
                var n = 0
                // A single read() may return fewer bytes than asked for.
                while (n < head.size) {
                    val r = i.read(head, n, head.size - n)
                    if (r <= 0) break
                    n += r
                }
                var found = false
                for (k in 0 until n - 1) {
                    if (head[k] == 'G'.code.toByte() &&
                        head[k + 1] == 'H'.code.toByte()
                    ) {
                        found = true
                        break
                    }
                }
                found
            }
        } catch (_: Throwable) {
            false
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
