(() => {
    "use strict";

    const canvas = document.querySelector("canvas");
    const presets = [
        { wave_mode: 0, wave_r: 0.2, wave_g: 0.9, wave_b: 1.0, rot: 0.01, zoom: 1.015, decay: 0.95 },
        { wave_mode: 5, wave_r: 1.0, wave_g: 0.35, wave_b: 0.65, rot: -0.025, zoom: 0.99, decay: 0.94 },
        { wave_mode: 7, wave_r: 0.55, wave_g: 1.0, wave_b: 0.28, rot: 0.02, zoom: 1.02, decay: 0.93 }
    ];
    const audio = new Uint8Array(1024);
    const audioLevels = { timeByteArray: audio, timeByteArrayL: audio, timeByteArrayR: audio };
    let visualizer;
    let selectedPreset = -1;

    // Swift supplies decoded, post-EQ mono PCM. This path needs no Web Audio output or input.
    window.renderMacampMilkDrop = async (samples, presetIndex) => {
        const scale = Math.min(window.devicePixelRatio || 1, 2);
        const width = Math.max(1, Math.min(2560, Math.round(canvas.clientWidth * scale)));
        const height = Math.max(1, Math.min(1440, Math.round(canvas.clientHeight * scale)));
        if (!visualizer) {
            canvas.width = width;
            canvas.height = height;
            visualizer = window.butterchurn.createVisualizer(null, canvas, { width, height, pixelRatio: 1 });
        } else if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
            visualizer.setRendererSize(width, height);
        }
        if (selectedPreset !== presetIndex) {
            await visualizer.loadPreset({
                baseVals: { ...presets[presetIndex], wave_a: 0.9, wave_scale: 1.2 },
                init_eqs_str: "",
                frame_eqs_str: "a.wave_r += a.bass * 0.08; a.wave_b += a.treb * 0.08;",
                pixel_eqs_str: "",
                shapes: Array.from({ length: 4 }, () => ({ baseVals: { enabled: 0 } })),
                waves: Array.from({ length: 4 }, () => ({ baseVals: { enabled: 0 } }))
            }, 0);
            selectedPreset = presetIndex;
        }
        audio.fill(128);
        const count = Math.min(samples.length, audio.length);
        for (let index = 0; index < count; index++) {
            const sample = samples[samples.length - count + index];
            audio[audio.length - count + index] = Math.max(0, Math.min(255, Math.round(128 + 128 * sample)));
        }
        visualizer.render({ audioLevels });
        return true;
    };
})();
