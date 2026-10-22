# Visualization compatibility

Built-in modes are spectrum bars, oscilloscope, mirrored spectrum, radial spectrum, starfield tunnel, classic peak hold, album-art ambience, and retro pattern. The renderer consumes a shared analyzed frame, independent of playback providers. The floating visualization and visualization regions in Classic and Modern skins read the same latest frame.

Local file playback exposes post-EQ PCM from the local audio engine. A tap copies mono samples into a four-slot bounded single-producer/single-consumer ring; it performs no allocation, lock acquisition, or UI/stream delivery on the real-time callback. When the ring is full, the callback drops the newest frame. The consumer applies a Hann window and Accelerate/vDSP FFT, then emits log-spaced bands and a waveform at the configured UI frame rate. Paused or unsupported routes show an unavailable/silent state instead of fabricated levels.

Apple Music, hosted playback, and AVPlayer URL routes do not expose decoded PCM to Macamp. Macamp does not capture a microphone or system audio, and it does not simulate data by default. `LocalPCMAudioAnalysisSource` accepts only decoded local-engine buffers, after the equalizer node.

Macamp’s JSON preset is versioned and rejects unsupported versions. AVS and MilkDrop importers may be added behind a safe parser; unsupported fields should remain diagnostic data. Windows visualization DLLs will not be loaded, and preset scripts will never run without a deliberately sandboxed reviewed interpreter.
