(() => {
    "use strict";

    const canvas = document.querySelector("canvas");
    const builtInPresets = [
        { wave_mode: 0, wave_r: 0.2, wave_g: 0.9, wave_b: 1.0, rot: 0.01, zoom: 1.015, decay: 0.95 },
        { wave_mode: 5, wave_r: 1.0, wave_g: 0.35, wave_b: 0.65, rot: -0.025, zoom: 0.99, decay: 0.94 },
        { wave_mode: 7, wave_r: 0.55, wave_g: 1.0, wave_b: 0.28, rot: 0.02, zoom: 1.02, decay: 0.93 }
    ];
    const audio = new Uint8Array(1024);
    const audioLevels = { timeByteArray: audio, timeByteArrayL: audio, timeByteArrayR: audio };
    let visualizer;
    let selectedPresetKey = "";

    function fixImageTextureUpload() {
        const imageTextures = visualizer.renderer.image;
        const gl = visualizer.renderer.gl;
        imageTextures.bindTexture = function (texture, image) {
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
            gl.generateMipmap(gl.TEXTURE_2D);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            if (imageTextures.anisoExt) {
                const ext = imageTextures.anisoExt;
                gl.texParameterf(gl.TEXTURE_2D, ext.TEXTURE_MAX_ANISOTROPY_EXT,
                    gl.getParameter(ext.MAX_TEXTURE_MAX_ANISOTROPY_EXT));
            }
        };
    }

    // Swift supplies decoded, post-EQ mono PCM. This path needs no Web Audio output or input.
    window.renderMacampMilkDrop = async (samples, presetIndex, customPresetJSON, presetKey, customTextureJSON) => {
        const scale = Math.min(window.devicePixelRatio || 1, 2);
        const width = Math.max(1, Math.min(2560, Math.round(canvas.clientWidth * scale)));
        const height = Math.max(1, Math.min(1440, Math.round(canvas.clientHeight * scale)));
        if (!visualizer) {
            canvas.width = width;
            canvas.height = height;
            visualizer = window.butterchurn.createVisualizer(null, canvas, { width, height, pixelRatio: 1 });
            fixImageTextureUpload();
        } else if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
            visualizer.setRendererSize(width, height);
        }
        if (selectedPresetKey !== presetKey) {
            const textures = customTextureJSON ? JSON.parse(customTextureJSON) : {};
            if (Object.keys(textures).length > 0) visualizer.loadExtraImages(textures);
            const preset = presetIndex < builtInPresets.length
                ? {
                    baseVals: { ...builtInPresets[presetIndex], wave_a: 0.9, wave_scale: 1.2 },
                    init_eqs_str: "",
                    frame_eqs_str: "a.wave_r += a.bass * 0.08; a.wave_b += a.treb * 0.08;",
                    pixel_eqs_str: "",
                    warp: "",
                    comp: "",
                    shapes: Array.from({ length: 4 }, () => ({ baseVals: { enabled: 0 } })),
                    waves: Array.from({ length: 4 }, () => ({ baseVals: { enabled: 0 } }))
                }
                : JSON.parse(customPresetJSON);
            await visualizer.loadPreset(preset, 0);
            selectedPresetKey = presetKey;
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
