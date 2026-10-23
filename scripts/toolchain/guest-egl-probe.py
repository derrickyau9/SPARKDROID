"""Render and read a pixel through an explicit Linux VirtIO DRM render node."""
import ctypes as c
import json
import os
import time

def fn(lib, name, result, *arguments):
    entry = getattr(lib, name)
    entry.restype = result
    entry.argtypes = list(arguments)
    return entry

def main():
    gbm = c.CDLL("libgbm.so.1")
    egl = c.CDLL("libEGL.so.1")
    gl = c.CDLL("libGLESv2.so.2")
    ptr, integer, uint = c.c_void_p, c.c_int, c.c_uint
    create_gbm = fn(gbm, "gbm_create_device", ptr, integer)
    destroy_gbm = fn(gbm, "gbm_device_destroy", None, ptr)
    display_for = fn(egl, "eglGetPlatformDisplay", ptr, uint, ptr, c.POINTER(c.c_ssize_t))
    initialize = fn(egl, "eglInitialize", uint, ptr, c.POINTER(integer), c.POINTER(integer))
    choose = fn(egl, "eglChooseConfig", uint, ptr, c.POINTER(integer), c.POINTER(ptr), integer, c.POINTER(integer))
    bind = fn(egl, "eglBindAPI", uint, uint)
    context_for = fn(egl, "eglCreateContext", ptr, ptr, ptr, ptr, c.POINTER(integer))
    make_current = fn(egl, "eglMakeCurrent", uint, ptr, ptr, ptr, ptr)
    string_for = fn(gl, "glGetString", c.c_char_p, uint)
    create_tex = fn(gl, "glGenTextures", None, integer, c.POINTER(uint))
    bind_tex = fn(gl, "glBindTexture", None, uint, uint)
    texture = fn(gl, "glTexImage2D", None, uint, integer, integer, integer, integer, integer, uint, uint, ptr)
    create_fb = fn(gl, "glGenFramebuffers", None, integer, c.POINTER(uint))
    bind_fb = fn(gl, "glBindFramebuffer", None, uint, uint)
    attach = fn(gl, "glFramebufferTexture2D", None, uint, uint, uint, uint, integer)
    fb_status = fn(gl, "glCheckFramebufferStatus", uint, uint)
    clear_color = fn(gl, "glClearColor", None, c.c_float, c.c_float, c.c_float, c.c_float)
    clear = fn(gl, "glClear", None, uint)
    read = fn(gl, "glReadPixels", None, integer, integer, integer, integer, uint, uint, ptr)
    error = fn(gl, "glGetError", uint)
    fd = os.open("/dev/dri/renderD128", os.O_RDWR)
    device = create_gbm(fd)
    if not device:
        raise RuntimeError("gbm_create_device failed for renderD128")
    display = display_for(0x31D7, device, None)  # EGL_PLATFORM_GBM_KHR
    major, minor = integer(), integer()
    if not initialize(display, c.byref(major), c.byref(minor)):
        raise RuntimeError("EGL initialization on VirtIO GBM failed")
    config, available = ptr(), integer()
    attrs = (integer * 5)(0x3033, 0, 0x3040, 4, 0x3038)
    if not choose(display, attrs, c.byref(config), 1, c.byref(available)) or available.value < 1:
        raise RuntimeError("EGL GBM ES2 configuration unavailable")
    bind(0x30A0)
    context_attrs = (integer * 3)(0x3098, 2, 0x3038)
    context = context_for(display, config, None, context_attrs)
    if not context or not make_current(display, None, None, context):
        raise RuntimeError("EGL surfaceless GBM context unavailable")
    tex, fb = uint(), uint()
    create_tex(1, c.byref(tex))
    bind_tex(0x0DE1, tex.value)
    texture(0x0DE1, 0, 0x1908, 4, 4, 0, 0x1908, 0x1401, None)
    create_fb(1, c.byref(fb))
    bind_fb(0x8D40, fb.value)
    attach(0x8D40, 0x8CE0, 0x0DE1, tex.value, 0)
    complete = fb_status(0x8D40) == 0x8CD5
    clear_color(0.2, 0.4, 0.6, 1.0)
    clear(0x00004000)
    pixel = (c.c_ubyte * 4)()
    read(0, 0, 1, 1, 0x1908, 0x1401, pixel)
    gl_error = error()
    renderer = string_for(0x1F01).decode()
    accelerated = "virgl" in renderer.lower() and "nvidia" in renderer.lower()
    valid_pixel = all(abs(pixel[i] - value) <= 1 for i, value in enumerate([51, 102, 153, 255]))
    print(json.dumps({"success": complete and gl_error == 0 and valid_pixel and accelerated,
        "timestampUnix": time.time(), "node": "/dev/dri/renderD128", "eglVersion": f"{major.value}.{minor.value}",
        "glVendor": string_for(0x1F00).decode(), "glRenderer": renderer,
        "glVersion": string_for(0x1F02).decode(), "framebufferComplete": complete,
        "pixelRGBA": list(pixel), "glError": gl_error, "acceleratedRenderer": accelerated,
        "note": "Linux guest GLES rendering through VirtIO/VirGL/ANGLE/NVIDIA; Android rendering not yet established."}, indent=2))
    make_current(display, None, None, None)
    fn(egl, "eglDestroyContext", uint, ptr, ptr)(display, context)
    fn(egl, "eglTerminate", uint, ptr)(display)
    destroy_gbm(device)
    os.close(fd)

if __name__ == "__main__":
    try:
        main()
    except Exception as exception:
        print(json.dumps({"success": False, "error": str(exception)}))
        raise
