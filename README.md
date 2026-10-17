# MusicFlow

A native Metal reconstruction of Apple Music's animated artwork background, with readable shaders and a standalone macOS demo.

![MusicFlow rendered with Metal](Validation/animation.gif)

**150 GPU comparison cases matched the original shaders exactly:** zero difference in every tested 10-bit RGB channel at the rotation, blur, and final output stages on an Apple M4.

This result applies to the recorded test inputs and reconstructed rendering pipeline. It is not an end-to-end frame capture comparison against the running Apple Music app.

## Try it

Download the Apple Silicon app from [Releases](https://github.com/frs0n/MusicFlow/releases/latest), unzip it, and open `MusicFlow.app`.

The demo supports local artwork, crossfades, five morph meshes, light and dark appearances, pause/resume, animation timing, and PNG export. Normal operation compiles and runs the rewritten `Flow.metal`; it does not load Apple Music's shader library.

### Build from source

Requires macOS 14 or later and an Xcode toolchain with Swift 5.9 or later. The published build and GPU comparisons were tested on Apple Silicon.

```sh
git clone https://github.com/frs0n/MusicFlow.git
cd MusicFlow
./build-app.sh
open ../MusicFlow.app
```

The app compiles its bundled Metal source using `MTLDevice.makeLibrary(source:)`. A separately installed offline Metal compiler is not required.

## Rendering pipeline

```text
Artwork textures + crossfade queue
    → Three rotating instances
    → MPS Gaussian blur, or horizontal + vertical blur passes
    → Morph between two subdivided meshes
    → Saturation, light/dark scrims, and color-range clamp
    → 10-bit MTKView presentation on supported Apple GPUs
```

The implementation reconstructs:

- The three instance transforms and their 120/90/70 timing scales.
- Source/destination texture mixing and replacement-color branches.
- Both the `MPSImageGaussianBlur` path and the separable Metal blur shaders.
- The mesh morph curve, including `acos(sin(...))`, the smoothstep polynomial, and the 0.8 UV scale.
- Two-stage saturation, light/dark scrims, and the 0.07–0.97 final clamp.
- The 368-byte uniform buffer and 56-byte mesh vertex layout.
- All five recovered 6×6 control meshes, subdivided into 1,681 vertices and 1,600 quads per mesh.
- sRGB artwork textures, mipmaps, 300-pixel longest-edge preprocessing, and the common RGBA8 luminosity branch.
- Fixed frame steps, 0.5-second crossfades, and Reduce Motion timing.
- BGR10A2 render targets and presentation on supported Apple GPUs.

Sampling is nearest-neighbor, as confirmed by comparison with the original shaders. Substituting linear filtering produces measurable differences.

## GPU validation

The validation executable renders the same inputs through two shader backends:

1. The rewritten Metal source in this repository.
2. The corresponding functions in the locally installed Apple Music `default.metallib`.

Both backends use the same reconstructed CPU pipeline, uniforms, meshes, input textures, and render-target format. Textures are read back from the GPU and compared channel by channel.

| Stage | Tested cases | Maximum channel difference | Mean channel difference |
| --- | ---: | ---: | ---: |
| Rotation | 150 | 0 | 0 |
| Blur | 150 | 0 | 0 |
| Final output | 150 | 0 | 0 |

The recorded run used an Apple M4 and BGR10A2 (10-bit RGB) targets. Its test matrix covers five meshes, five time/transition states, two blur paths, and three resolutions: 960×640, 511×769, and 320×320. Cases include light/dark appearances, transitions with and without a destination texture, replacement colors, and mipmapped sRGB inputs with high-frequency detail.

- [Machine-readable results](Validation/comparison.json)
- [Rewritten shader output](Validation/reconstructed.png)
- [Original shader output](Validation/original-shaders.png)
- [Original artifact identity and hashes](Validation/original-artifact.json)

Reproduce the comparison on a Mac with the matching Music shader library:

```sh
./build-app.sh
../MusicFlow.app/Contents/MacOS/MusicFlow --validate --output Validation
```

Validation reads `/System/Applications/Music.app/Contents/Resources/default.metallib`. It does not launch Apple Music or depend on playback. Any nonzero channel difference makes validation fail; a different OS, Music build, or GPU may produce different results.

The preview GIF contains 40 distinct GPU-rendered frames. Its four-second playback loop is a presentation loop, not the background's full animation period.

## Source map

| File | Purpose |
| --- | --- |
| [`Flow.metal`](Sources/MusicFlow/Resources/Flow.metal) | Rewritten rendering shaders |
| [`FlowRenderer.swift`](Sources/MusicFlow/FlowRenderer.swift) | Rotation, blur, mesh encoding, and presentation |
| [`FlowTypes.swift`](Sources/MusicFlow/FlowTypes.swift) | Model transforms, uniform layout, and parameters |
| [`Artwork.swift`](Sources/MusicFlow/Artwork.swift) | Texture loading, preprocessing, and luminosity |
| [`App.swift`](Sources/MusicFlow/App.swift) | Native macOS demo |
| [`Validation.swift`](Sources/MusicFlow/Validation.swift) | GPU comparison and preview generation |
| [`ExportSubdividedMeshes.m`](Tools/ExportSubdividedMeshes.m) | Development-only mesh export utility |

## Reconstruction scope

The reference artifact is macOS Music 1.7.2. The implementation was recovered from its AIR shader bitcode, Objective-C metadata, ARM64 instructions, and mesh tables.

The pixel comparisons establish shader equivalence for the finite recorded cases under the reconstructed pipeline. They do not establish full Apple Music runtime equivalence across every screen, input, OS version, or device. No runtime GPU frame capture of Apple Music was taken. The image-loading entry point canonicalizes input to sRGB RGBA8; the original binary's other grayscale and 16-bit luminosity branches have not all been ported. The iOS implementation has not been verified.

The runtime app uses pre-exported mesh data and does not call the private subdivision API. To regenerate that data locally, the development utility uses the same system subdivision interface as the reference:

```sh
xcrun clang -fobjc-arc -framework Foundation -framework QuartzCore \
  Tools/ExportSubdividedMeshes.m -o /tmp/musicflow-export-meshes
/tmp/musicflow-export-meshes Tools/mesh-templates.json \
  Sources/MusicFlow/Resources/SubdividedMeshes.json
```

This is an independent reconstruction, not an Apple project. No Apple application executable, original metallib, or extracted shader bitcode is included in this repository.
