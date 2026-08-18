#!/usr/bin/env python3
"""One-off patch: force speech_to_text plugin to use Google TTS recognizer."""
import sys

p = "/Users/tungdl/.pub-cache/hosted/pub.dev/speech_to_text-7.4.0/android/src/main/kotlin/com/csdcorp/speech_to_text/SpeechToTextPlugin.kt"
src = open(p).read()

old = """                    if ( null == speechRecognizer) {
                            speechRecognizer = createSpeechRecognizer(pluginContext).apply {
                                debugLog("Setting default listener")
                                setRecognitionListener(this@SpeechToTextPlugin)
                        }
                    }"""

new = """                    if ( null == speechRecognizer) {
                            // NAVBRIDGE PATCH: the default recognition service (Android
                            // System Intelligence / AiAi) returns NO_SPEECH_DETECTED for
                            // clear speech on low-end itel devices. Force Google TTS'
                            // network recognizer, falling back to the default if missing.
                            val gtts = ComponentName(
                                "com.google.android.tts",
                                "com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService"
                            )
                            speechRecognizer = try {
                                createSpeechRecognizer(pluginContext, gtts).apply {
                                    debugLog("Setting GoogleTTS listener")
                                    setRecognitionListener(this@SpeechToTextPlugin)
                                }
                            } catch (t: Throwable) {
                                debugLog("GoogleTTS recognizer unavailable: ${t.message}; falling back to default")
                                null
                            }
                            if (speechRecognizer == null) {
                                speechRecognizer = createSpeechRecognizer(pluginContext).apply {
                                    debugLog("Setting default listener")
                                    setRecognitionListener(this@SpeechToTextPlugin)
                                }
                            }
                    }"""

count = src.count(old)
if count != 1:
    print(f"FAIL: pattern found {count} times")
    sys.exit(1)

open(p, "w").write(src.replace(old, new))
print("PATCHED OK")
