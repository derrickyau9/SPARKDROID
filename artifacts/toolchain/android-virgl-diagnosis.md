# Android VirGL failure: bounded diagnosis

The Android hardware-mode trial booted its framework but rendered a black screenshot. SurfaceFlinger reported the VirtIO/VirGL/NVIDIA path with OpenGL ES 2.0 Mesa 24.0.8. The Windows host logged an incomplete framebuffer `0x8d56`, followed by GL error 1286 and a rejected CLEAR. This is a real Android rendering failure despite a working simple Linux offscreen render.

The exact packaged ANGLE commit `890b5d8fa298` checks framebuffer completeness in `src/libANGLE/Framebuffer.cpp`. Its `0x8d56` paths cover inconsistent attachment sample counts, a requested sample count above the format's supported maximum, inconsistent fixed sample locations, and incompatible multisample textures/renderbuffers. This narrows the error to framebuffer sample compatibility; it does not identify which particular attachment or allocation is wrong. GL error 1286 is consistent with a subsequent operation against an incomplete framebuffer.

The SurfaceFlinger dump advertises `GL_EXT_multisampled_render_to_texture` and its second revision, and shows Skia render-target and stencil allocations. The simple Linux proof used a single-sample color texture with no stencil attachment. It did not exercise the Android multisample/stencil path. That difference explains why the simple proof cannot certify Android graphics, but is not an independently proven root cause.

The Android upstream VirGLrenderer source shows distinct handling for implicit multisample color attachments and depth/stencil attachments. The packaged renderer is MSYS2 VirGLrenderer 1.3.0; the fetched Android source excerpt is a comparison reference rather than a claim that every line matches that binary. An attachment trace is needed before assigning the fault to Android Mesa, VirGLrenderer, ANGLE, or the NVIDIA driver.

Useful next instrumentation is to log the actual host framebuffer attachments, formats, requested/actual sample counts, fixed-sample-location flags, and status immediately before the failing SurfaceFlinger CLEAR. Also preserve the negotiated VirGL caps and extension sets. Do not bypass framebuffer validation or force unsupported GLES version numbers; those changes would not demonstrate correct rendering. No unverified graphics patch was applied during this diagnosis.

The working package should remain `software-explicit` until the Android composition workload produces valid frames through this hardware path. Host D3D11 and Linux VirGL results remain valid and are stored separately.

References:

- [Exact ANGLE framebuffer validation source](https://github.com/google/angle/blob/890b5d8fa298/src/libANGLE/Framebuffer.cpp)
- [Android upstream VirGLrenderer framebuffer implementation](https://android.googlesource.com/platform/external/virglrenderer/+/refs/heads/main/src/vrend_renderer.c)
- Local failure evidence: `artifacts/acceptance/graphics.json`, `android-virgl-surfaceflinger.txt`, `android-virgl-qemu-errors.log`, and `android-virgl-check.png`.

Downloaded code excerpts are saved under `artifacts/toolchain/sources`. No exact failing attachment state was captured, so a particular implementation defect is not asserted.
