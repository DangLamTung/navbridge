#!/usr/bin/env python3
"""Cleanup: remove the stale duplicate 20000 min-length block from the plugin."""
import sys

p = "/Users/tungdl/.pub-cache/hosted/pub.dev/speech_to_text-7.4.0/android/src/main/kotlin/com/csdcorp/speech_to_text/SpeechToTextPlugin.kt"
src = open(p).read()

dup = """                        // NAVBRIDGE PATCH: force the recognizer to hold the mic
                        // open for at least MIN_INPUT ms of audio before it is
                        // allowed to decide "no speech". Low-end itel devices
                        // otherwise bail with NO_SPEECH_DETECTED after ~1 s.
                        putExtra(
                            RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                            20000
                        )
                        putExtra(
                            RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                            pauseFor ?: 2500
                        )
"""

count = src.count(dup)
if count != 1:
    print(f"FAIL: duplicate block found {count} times")
    sys.exit(1)

open(p, "w").write(src.replace(dup, ""))
print("CLEANED OK")
