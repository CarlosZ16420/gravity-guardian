using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class ProcessTreeTrace
{
    private const uint DebugProcess = 1;
    private const int CreateProcessEvent = 3;
    private const int ExitProcessEvent = 5;
    private const int LoadDllEvent = 6;
    private const int ExceptionEvent = 1;
    private const uint Breakpoint = 0x80000003;
    private const uint DebugContinue = 0x00010002;
    private const uint ExceptionNotHandled = 0x80010001;
    private const int WaitTimeout = 121;

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        private IntPtr reserved, desktop, title;
        private int x, y, width, height, textWidth, textHeight, fillAttribute, flags;
        private short showWindow, reservedSize;
        private IntPtr reservedBytes, input, output, error;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public int ProcessId, ThreadId;
    }

    // Windows x64 DEBUG_EVENT has a 16-byte header followed by a 160-byte union.
    [StructLayout(LayoutKind.Explicit, Size = 176)]
    private struct DebugEvent
    {
        [FieldOffset(0)] public int Code;
        [FieldOffset(4)] public int ProcessId;
        [FieldOffset(8)] public int ThreadId;
        [FieldOffset(16)] public IntPtr File;
        [FieldOffset(16)] public uint ExceptionCode;
        [FieldOffset(16)] public int ExitCode;
        [FieldOffset(24)] public IntPtr Process;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processSecurity,
        IntPtr threadSecurity, bool inheritHandles, uint flags, IntPtr environment, string workingDir,
        ref StartupInfo startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WaitForDebugEvent(out DebugEvent debugEvent, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ContinueDebugEvent(int processId, int threadId, uint status);
    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public sealed class Result
    {
        public int ExitCode { get; set; }
        public List<ProcessStart> Starts { get; } = new List<ProcessStart>();
    }

    public sealed class ProcessStart
    {
        public int ProcessId { get; }
        public string Image { get; }

        public ProcessStart(int processId, string image)
        {
            ProcessId = processId;
            Image = image;
        }
    }

    public static Result Run(string application, string commandLine, string workingDir)
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("The process tracing fixture requires Windows x64");

        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (!CreateProcess(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
            true, DebugProcess, IntPtr.Zero, workingDir, ref startup, out var process))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot start the traced test process");

        CloseHandle(process.Process);
        CloseHandle(process.Thread);
        var result = new Result();
        var running = new HashSet<int> { process.ProcessId };
        var initialBreakpoints = new HashSet<int>();
        var timeout = Stopwatch.StartNew();
        while (running.Count > 0)
        {
            if (timeout.Elapsed > TimeSpan.FromMinutes(5))
                throw new TimeoutException("Timed out collecting isolated process starts");
            if (!WaitForDebugEvent(out var next, 1000))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == WaitTimeout) continue;
                throw new Win32Exception(error, "Cannot receive a debug event");
            }

            uint status = DebugContinue;
            if (next.Code == CreateProcessEvent)
            {
                if (next.File != IntPtr.Zero) CloseHandle(next.File);
                var path = new StringBuilder(32768);
                int length = path.Capacity;
                if (!QueryImageName(next.Process, 0, path, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot identify a traced process");
                result.Starts.Add(new ProcessStart(next.ProcessId, path.ToString()));
                running.Add(next.ProcessId);
                initialBreakpoints.Add(next.ProcessId);
            }
            else if (next.Code == LoadDllEvent && next.File != IntPtr.Zero)
                CloseHandle(next.File);
            else if (next.Code == ExitProcessEvent)
            {
                running.Remove(next.ProcessId);
                initialBreakpoints.Remove(next.ProcessId);
                if (next.ProcessId == process.ProcessId) result.ExitCode = next.ExitCode;
            }
            else if (next.Code == ExceptionEvent && (next.ExceptionCode != Breakpoint || !initialBreakpoints.Remove(next.ProcessId)))
                status = ExceptionNotHandled;

            if (!ContinueDebugEvent(next.ProcessId, next.ThreadId, status))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot continue a traced process");
        }
        return result;
    }
}
