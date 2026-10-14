import com.graphhopper.GraphHopper;
import com.graphhopper.config.Profile;
import com.graphhopper.routing.ev.BooleanEncodedValue;
import com.graphhopper.routing.ev.EnumEncodedValue;
import com.graphhopper.routing.ev.RoadClass;
import com.graphhopper.routing.util.EdgeFilter;
import com.graphhopper.storage.index.Snap;

/**
 * Reads the per-direction `car_access` bits of the edge under a coordinate —
 * the graph's own record of one-way vs two-way, which `roadInfo` currently
 * cannot report (GraphHopper 7 has no `oneway` encoded value, so the app read
 * every street as "form unknown" and fell back to the zone ceiling).
 *
 * Usage: ProbeOneway <graph-dir> <in.osm.pbf> <lat,lng> [more...]
 */
public class ProbeOneway {
    public static void main(String[] args) {
        String dir = args[0], osm = args[1];
        GraphHopper gh = new GraphHopper();
        gh.setOSMFile(osm);
        gh.setGraphHopperLocation(dir);
        gh.setProfiles(new Profile("car").setVehicle("car").setWeighting("fastest"));
        gh.importOrLoad();

        var em = gh.getEncodingManager();
        var access = em.getBooleanEncodedValue("car_access");
        EnumEncodedValue<RoadClass> rc = em.getEnumEncodedValue("road_class", RoadClass.class);
        System.out.println("has car_access=" + (access != null)
                + "  storeTwoDirections=" + (access != null && access.isStoreTwoDirections()));
        var idx = gh.getLocationIndex();

        for (int i = 2; i < args.length; i++) {
            String[] p = args[i].split(",");
            double lat = Double.parseDouble(p[0]), lng = Double.parseDouble(p[1]);
            Snap snap = idx.findClosest(lat, lng, EdgeFilter.ALL_EDGES);
            if (snap == null || !snap.isValid()) {
                System.out.println("  " + args[i] + " -> no edge");
                continue;
            }
            var e = snap.getClosestEdge();
            boolean fwd = e.get(access);
            // The reverse direction of the SAME edge: a one-way way has access
            // in exactly one of the two.
            boolean bwd = e.getReverse(access);
            System.out.printf("  %-22s %-28s %-14s fwd=%-5s bwd=%-5s dist=%.1fm%n",
                    args[i], String.valueOf(e.getName()), e.get(rc), fwd, bwd,
                    snap.getQueryDistance());
        }
        gh.close();
    }
}
