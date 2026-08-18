#!/usr/bin/env python3
"""One-off patch: force speech_to_text plugin to set a minimum input length so
the recognizer cannot bail with NO_SPEECH_DETECTED after ~1s on low-end itels."""
import sys

p = "/Users/tungdl/.pub-cache/hosted/pub.dev/speech_to_text-7.4.0/android/src/main/kotlin/com/csdcorp/speech_to_text/SpeechToTextPlugin.kt"
src = open(p).read()

old = """                        pauseFor?.also {
                            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, it)
                        }"""

new = """                        pauseFor?.also {
                            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, it)
                        }
                        // NAVBRIDGE PATCH: force the recognizer to hold the mic
                        // open for at least MIN_INPUT ms of audio before it is
                        // allowed to decide "no speech". Low-end itel devices
                        // otherwise bail with NO_SPEECH_DETECTED after ~1 s.
                        // 3 s is enough to capture a command yet stays snappy
                        // (the result comes back right after the user stops).
                        putExtra(
                            RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                            3000
                        )
                        putExtra(
                            RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                            pauseFor ?: 2500
                        )"""

count = src.count(old)
if count != 1:
    print(f"FAIL: pattern found {count} times")
    sys.exit(1)

open(p, "w").write(src.replace(old, new))
print("PATCHED OK")
