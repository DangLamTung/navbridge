import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.GraphHopper;
import com.graphhopper.ResponsePath;
import com.graphhopper.config.Profile;

/**
 * Loads a built graph with the exact same config the app uses and routes a
 * test request. Usage: LoadTest <graph-dir>
 */
public class LoadTest {
    public static void main(String[] args) {
        String dir = args[0];
        GraphHopper gh = new GraphHopper();
        gh.setGraphHopperLocation(dir);
        gh.setProfiles(new Profile("car").setVehicle("car").setWeighting("fastest"));
        gh.importOrLoad();
        System.out.println("LOADED");
        GHResponse rsp = gh.route(new GHRequest(43.7311, 7.4198, 43.7389, 7.4270).setProfile("car"));
        if (rsp.hasErrors()) {
            System.out.println("ROUTE_ERRORS: " + rsp.getErrors());
        } else {
            ResponsePath p = rsp.getBest();
            System.out.println("ROUTE_OK dist=" + p.getDistance() + " steps=" + p.getInstructions().size());
            for (var ins : p.getInstructions()) {
                System.out.println("  " + ins.getName() + " sign=" + ins.getSign() + " d=" + ins.getDistance());
            }
        }
        gh.close();
    }
}
