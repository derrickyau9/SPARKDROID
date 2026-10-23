#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$BinaryDirectory,
    [string]$OutputPath,
    [ValidateRange(5,120)][int]$TimeoutSeconds = 45,
    [Parameter(DontShow)][switch]$ProbeWorker
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $BinaryDirectory) { $BinaryDirectory = Join-Path $ProjectRoot 'tools/qemu-arm64/clangarm64/bin' }
if (-not $OutputPath) { $OutputPath = Join-Path $ProjectRoot 'artifacts/toolchain/angle-renderer.json' }
$BinaryDirectory = [IO.Path]::GetFullPath($BinaryDirectory)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null

function Write-ProbeResult($Report) {
    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    $Report | Format-List success,glVendor,glRenderer,glVersion,error
}

if (-not $ProbeWorker) {
    # Never reuse this process's native modules: P/Invoke caches resolved libraries.
    $workerOutput = "$OutputPath.worker-$([Guid]::NewGuid().ToString('N')).tmp"
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',$PSCommandPath,
        '-ProjectRoot',$ProjectRoot,'-BinaryDirectory',$BinaryDirectory,
        '-OutputPath',$workerOutput,'-ProbeWorker')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $report = $null
    try {
        if (-not $process.Start()) { throw 'Could not start isolated PowerShell probe.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "ANGLE probe exceeded $TimeoutSeconds seconds; its isolated process was terminated."
        }
        $workerStdout = $stdout.GetAwaiter().GetResult()
        $workerStderr = $stderr.GetAwaiter().GetResult()
        if (-not (Test-Path -LiteralPath $workerOutput -PathType Leaf)) {
            throw "Probe returned exit $($process.ExitCode) without a report. $workerStderr"
        }
        $report = Get-Content -Raw -LiteralPath $workerOutput | ConvertFrom-Json
        $report | Add-Member -NotePropertyName isolatedProcess -NotePropertyValue $true
        $report | Add-Member -NotePropertyName processExitCode -NotePropertyValue $process.ExitCode
        $report | Add-Member -NotePropertyName processStderr -NotePropertyValue $workerStderr
        if ($process.ExitCode -ne 0) { $report.success = $false }
    } catch {
        $report = [pscustomobject]@{success=$false;error=$_.Exception.Message;
            timestampUtc=[DateTime]::UtcNow.ToString('o');binaryDirectory=$BinaryDirectory;
            isolatedProcess=$true;note='Host ANGLE clear/readback only; no WSA installation, boot or Android rendering was tested.'}
    } finally {
        $process.Dispose()
        if (Test-Path -LiteralPath $workerOutput -PathType Leaf) { Remove-Item -LiteralPath $workerOutput }
    }
    Write-ProbeResult $report
    return
}

$env:PATH = $binaryDirectory + [IO.Path]::PathSeparator + $env:PATH
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
public static class SparkAngleProbe {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetDllDirectory(string path);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetModuleFileName(IntPtr module, StringBuilder name, int size);
    static IntPtr eglLibrary, glesLibrary;
    static SparkAngleProbe() {
        NativeLibrary.SetDllImportResolver(typeof(SparkAngleProbe).Assembly,
            (name, assembly, searchPath) => name == "libEGL.dll" ? eglLibrary :
                name == "libGLESv2.dll" ? glesLibrary : IntPtr.Zero);
    }
    static string ModulePath(IntPtr module) {
        var text = new StringBuilder(32768);
        if (GetModuleFileName(module, text, text.Capacity) == 0) throw new Win32Exception();
        return text.ToString();
    }
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
        IntPtr display=IntPtr.Zero, surface=IntPtr.Zero, context=IntPtr.Zero;
        var loaded = new List<object>();
        var result = new Dictionary<string,object> {
            ["success"]=false, ["loadedLibraries"]=loaded,
            ["note"]="Host ANGLE clear and pixel readback only; WSA installation/boot, guest GPU rendering and Android compatibility are not established."
        };
        try {
            if (!SetDllDirectory(path)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetDllDirectory failed");
            string glesPath=Path.GetFullPath(Path.Combine(path,"libGLESv2.dll"));
            string eglPath=Path.GetFullPath(Path.Combine(path,"libEGL.dll"));
            glesLibrary=NativeLibrary.Load(glesPath);
            string actualGles=ModulePath(glesLibrary);
            loaded.Add(new {name="libGLESv2.dll",path=actualGles,requestedPath=glesPath});
            eglLibrary=NativeLibrary.Load(eglPath);
            string actualEgl=ModulePath(eglLibrary);
            loaded.Add(new {name="libEGL.dll",path=actualEgl,requestedPath=eglPath});
            if (!String.Equals(actualEgl,eglPath,StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(actualGles,glesPath,StringComparison.OrdinalIgnoreCase))
                throw new Exception("Loaded ANGLE module paths differ from the requested binary directory.");
            result["loadedPathsMatchRequested"]=true;
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
            result["success"]=readbackValid;
            result["eglVersion"]=major+"."+minor;
            result["eglVendor"]=Str(eglQueryString(display,0x3053));
            result["eglExtensions"]=Str(eglQueryString(display,0x3055));
            result["glVendor"]=Str(glGetString(0x1F00));
            result["glRenderer"]=Str(glGetString(0x1F01));
            result["glVersion"]=Str(glGetString(0x1F02));
            result["renderReadback"]=Convert.ToHexString(pixel);
            result["glError"]=glError;
        } catch (Exception error) {
            result["error"]=error.Message;
        } finally {
            try {
                if(display != IntPtr.Zero) {
                    eglMakeCurrent(display,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
                    if(surface != IntPtr.Zero) eglDestroySurface(display,surface);
                    if(context != IntPtr.Zero) eglDestroyContext(display,context);
                    eglTerminate(display);
                }
            } catch(Exception error) {
                result["success"]=false;
                result["cleanupError"]=error.Message;
            }
            SetDllDirectory(null);
        }
        return JsonSerializer.Serialize(result);
    }
}
'@
$result = [SparkAngleProbe]::Run($binaryDirectory) | ConvertFrom-Json
$result | Add-Member -NotePropertyName timestampUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$result | Add-Member -NotePropertyName binaryDirectory -NotePropertyValue $BinaryDirectory
$result | Add-Member -NotePropertyName processArchitecture -NotePropertyValue ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString())
foreach ($library in $result.loadedLibraries) {
    $stream = [IO.File]::OpenRead($library.path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Loaded file has no DOS executable header.' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Loaded file has no PE header.' }
        $machine = $reader.ReadUInt16()
        $architecture = switch ($machine) {
            0xAA64 { 'ARM64' }; 0xA641 { 'ARM64EC' }; 0xA64E { 'ARM64X' }
            0x8664 { 'AMD64' }; 0x014C { 'I386' }; default { 'Unknown' }
        }
        $library | Add-Member -NotePropertyName peMachine -NotePropertyValue ('0x{0:X4}' -f $machine)
        $library | Add-Member -NotePropertyName peArchitecture -NotePropertyValue $architecture
        $library | Add-Member -NotePropertyName fileSize -NotePropertyValue $stream.Length
    } finally { $reader.Dispose(); $stream.Dispose() }
    $library | Add-Member -NotePropertyName sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $library.path -Algorithm SHA256).Hash)
}
Write-ProbeResult $result
