#requires -Version 7.0
[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
$binaryDirectory = Join-Path $ProjectRoot 'tools/qemu-arm64/clangarm64/bin'
$env:PATH = $binaryDirectory + [IO.Path]::PathSeparator + $env:PATH
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text.Json;
public static class SparkAngleProbe {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetDllDirectory(string path);
    [DllImport("libEGL.dll")] static extern IntPtr eglGetDisplay(IntPtr display);
    [DllImport("libEGL.dll")] static extern int eglInitialize(IntPtr display, out int major, out int minor);
    [DllImport("libEGL.dll")] static extern IntPtr eglQueryString(IntPtr display, int name);
    [DllImport("libEGL.dll")] static extern int eglChooseConfig(IntPtr display, int[] attributes, IntPtr[] configs, int count, out int available);
    [DllImport("libEGL.dll")] static extern int eglBindAPI(int api);
    [DllImport("libEGL.dll")] static extern IntPtr eglCreateContext(IntPtr display, IntPtr config, IntPtr share, int[] attributes);
    [DllImport("libEGL.dll")] static extern IntPtr eglCreatePbufferSurface(IntPtr display, IntPtr config, int[] attributes);
    [DllImport("libEGL.dll")] static extern int eglMakeCurrent(IntPtr display, IntPtr draw, IntPtr read, IntPtr context);
    [DllImport("libEGL.dll")] static extern int eglDestroyContext(IntPtr display, IntPtr context);
    [DllImport("libEGL.dll")] static extern int eglDestroySurface(IntPtr display, IntPtr surface);
    [DllImport("libEGL.dll")] static extern int eglTerminate(IntPtr display);
    [DllImport("libEGL.dll")] static extern int eglGetError();
    [DllImport("libGLESv2.dll")] static extern IntPtr glGetString(int name);
    [DllImport("libGLESv2.dll")] static extern void glClearColor(float red, float green, float blue, float alpha);
    [DllImport("libGLESv2.dll")] static extern void glClear(uint mask);
    [DllImport("libGLESv2.dll")] static extern void glReadPixels(int x,int y,int width,int height,uint format,uint type,[Out] byte[] pixels);
    [DllImport("libGLESv2.dll")] static extern uint glGetError();
    static string Str(IntPtr value) => Marshal.PtrToStringAnsi(value) ?? "";
    static void Check(bool condition, string operation) { if (!condition) throw new Exception(operation + " failed; EGL error 0x" + eglGetError().ToString("X4")); }
    public static string Run(string path) {
        Check(SetDllDirectory(path), "SetDllDirectory");
        IntPtr display=IntPtr.Zero, surface=IntPtr.Zero, context=IntPtr.Zero;
        try {
            display = eglGetDisplay(IntPtr.Zero);
            Check(display != IntPtr.Zero, "eglGetDisplay");
            int major, minor;
            Check(eglInitialize(display, out major, out minor) != 0, "eglInitialize");
            var configs = new IntPtr[1]; int available;
            Check(eglChooseConfig(display, new[]{0x3033,1,0x3040,4,0x3024,8,0x3023,8,0x3022,8,0x3038},configs,1,out available) != 0 && available > 0,"eglChooseConfig");
            Check(eglBindAPI(0x30A0) != 0, "eglBindAPI");
            context = eglCreateContext(display, configs[0], IntPtr.Zero, new[]{0x3098,2,0x3038});
            Check(context != IntPtr.Zero, "eglCreateContext");
            surface = eglCreatePbufferSurface(display, configs[0], new[]{0x3057,16,0x3056,16,0x3038});
            Check(surface != IntPtr.Zero, "eglCreatePbufferSurface");
            Check(eglMakeCurrent(display,surface,surface,context) != 0,"eglMakeCurrent");
            glClearColor(0.2f,0.4f,0.6f,1.0f);
            glClear(0x00004000);
            var pixel = new byte[4];
            glReadPixels(0,0,1,1,0x1908,0x1401,pixel);
            uint glError = glGetError();
            bool readbackValid = glError == 0 && Math.Abs(pixel[0]-51)<=1 && Math.Abs(pixel[1]-102)<=1 && Math.Abs(pixel[2]-153)<=1;
            return JsonSerializer.Serialize(new {success=readbackValid,eglVersion=major+"."+minor,eglVendor=Str(eglQueryString(display,0x3053)),eglExtensions=Str(eglQueryString(display,0x3055)),glVendor=Str(glGetString(0x1F00)),glRenderer=Str(glGetString(0x1F01)),glVersion=Str(glGetString(0x1F02)),renderReadback=Convert.ToHexString(pixel),glError=glError,note="Host ANGLE clear and pixel readback only; guest GPU rendering and Android compatibility are not established."});
        } catch (Exception error) {
            return JsonSerializer.Serialize(new{success=false,error=error.Message});
        } finally {
            if(display != IntPtr.Zero) {
                eglMakeCurrent(display,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
                if(surface != IntPtr.Zero) eglDestroySurface(display,surface);
                if(context != IntPtr.Zero) eglDestroyContext(display,context);
                eglTerminate(display);
            }
            SetDllDirectory(null);
        }
    }
}
'@
$result = [SparkAngleProbe]::Run($binaryDirectory) | ConvertFrom-Json
$result | Add-Member -NotePropertyName timestampUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProjectRoot 'artifacts/toolchain/angle-renderer.json') -Encoding utf8
$result | Format-List success,glVendor,glRenderer,glVersion,error
