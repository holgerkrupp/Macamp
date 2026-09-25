# Visualization compatibility

Built-in modes are spectrum bars, oscilloscope, mirrored spectrum, radial spectrum, starfield tunnel, classic peak hold, album-art ambience, and retro pattern. The renderer consumes `VisualizationAudioData`, independent of playback providers.

Apple Music uses `SimulatedAudioAnalysisSource`: a deterministic seed derived from stable track metadata plus elapsed frames produces smooth repeatable bands/waveforms, stops movement while paused, and is labeled “SIMULATED • NO PCM CAPTURE.” Macamp does not capture a microphone or system audio.

`LocalPCMAudioAnalysisSource` is the boundary for a future local engine. Planned analysis uses safe mono mixing, a Hann window, Accelerate/vDSP FFT, logarithmic bands, smoothing, peak hold/decay, and a bounded non-blocking handoff. UI frame rate remains independent from the audio callback.

Macamp’s JSON preset is versioned and rejects unsupported versions. AVS and MilkDrop importers may be added behind a safe parser; unsupported fields should remain diagnostic data. Windows visualization DLLs will not be loaded, and preset scripts will never run without a deliberately sandboxed reviewed interpreter.
