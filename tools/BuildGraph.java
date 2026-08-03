import com.graphhopper.GraphHopper;
import com.graphhopper.config.Profile;

/**
 * Builds a GraphHopper car graph from an OSM PBF, using exactly the same
 * profile the NavBridge app loads on-device (GraphHopper 8.0, setVehicle +
 * setWeighting — no custom-model expression compilation, which does not work
 * on Android).
 *
 * Usage: BuildGraph <in.osm.pbf> <out-graph-dir>
 */
public class BuildGraph {
    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("Usage: BuildGraph <in.osm.pbf> <out-graph-dir>");
            System.exit(2);
        }
        String osm = args[0];
        String out = args[1];

        GraphHopper gh = new GraphHopper();
        gh.setOSMFile(osm);
        gh.setGraphHopperLocation(out);
        gh.setProfiles(new Profile("car").setVehicle("car").setWeighting("fastest"));
        gh.importOrLoad();
        gh.close();
        System.out.println("GRAPH_READY: " + out);
    }
}
