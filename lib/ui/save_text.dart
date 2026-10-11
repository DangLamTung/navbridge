/// Hand a text document (a trip's JSON) to the platform, so a run in the browser
/// produces something the user can KEEP.
///
/// ⭐ WHY this exists instead of a server. The web build has no documents
/// directory and no `path_provider`, so `saveTrip()` cannot write a file — which
/// left the simulated drive's result visible only in the console log and in a
/// POST to a harness that had to be running to receive it. The point of the
/// simulation is that its OUTPUT is a trip document; on web that has to be a
/// download, and on a device the same call shares it. Anything that needs a
/// running helper to observe the result is not the app producing a result.
library;

export 'save_text_stub.dart'
    if (dart.library.html) 'save_text_web.dart'
    if (dart.library.io) 'save_text_io.dart';
