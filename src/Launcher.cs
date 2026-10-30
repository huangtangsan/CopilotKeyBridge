using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class Launcher
{
    private const int SwRestore = 9;
    private const uint GwOwner = 4;
    private const int GwlExStyle = -20;
    private const long WsExToolWindow = 0x00000080L;
    private const uint ProcessQueryLimitedInformation = 0x1000;

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong32(IntPtr window, int index);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(
        IntPtr process,
        uint flags,
        StringBuilder path,
        ref uint size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [STAThread]
    private static int Main()
    {
        bool ownsMutex;
        using (Mutex mutex = new Mutex(true, @"Local\CopilotKeyBridge.Launcher", out ownsMutex))
        {
            if (!ownsMutex)
                return 0;

            try
            {
                string target = ReadTargetPath();
                if (!File.Exists(target))
                    throw new FileNotFoundException("The configured target does not exist.", target);

                if (TryActivateTarget(target))
                    return 0;

                Process.Start(new ProcessStartInfo
                {
                    FileName = target,
                    WorkingDirectory = Path.GetDirectoryName(target),
                    UseShellExecute = false
                });
                return 0;
            }
            catch (Exception error)
            {
                Log(error);
                return 1;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
    }

    private static string ReadTargetPath()
    {
        string configPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "target.b64");
        string encoded = File.ReadAllText(configPath, Encoding.ASCII).Trim();
        string target = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
        return Path.GetFullPath(target);
    }

    private static bool TryActivateTarget(string target)
    {
        IntPtr candidate = IntPtr.Zero;
        int currentSession = Process.GetCurrentProcess().SessionId;

        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if ((!IsWindowVisible(window) && !IsIconic(window)) || GetWindow(window, GwOwner) != IntPtr.Zero)
                return true;

            long extendedStyle = IntPtr.Size == 8
                ? GetWindowLongPtr64(window, GwlExStyle).ToInt64()
                : GetWindowLong32(window, GwlExStyle);
            if ((extendedStyle & WsExToolWindow) != 0)
                return true;

            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == 0)
                return true;

            try
            {
                using (Process process = Process.GetProcessById((int)processId))
                {
                    if (process.SessionId != currentSession)
                        return true;
                }
            }
            catch
            {
                return true;
            }

            string processPath = GetProcessPath(processId);
            if (!string.Equals(processPath, target, StringComparison.OrdinalIgnoreCase))
                return true;

            candidate = window;
            return false;
        }, IntPtr.Zero);

        if (candidate == IntPtr.Zero)
            return false;

        ShowWindowAsync(candidate, SwRestore);
        for (int attempt = 0; attempt < 10; attempt++)
        {
            SetForegroundWindow(candidate);
            if (GetForegroundWindow() == candidate)
                break;
            Thread.Sleep(50);
        }
        return true;
    }

    private static string GetProcessPath(uint processId)
    {
        IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero)
            return null;

        try
        {
            uint capacity = 32768;
            StringBuilder path = new StringBuilder((int)capacity);
            return QueryFullProcessImageName(process, 0, path, ref capacity)
                ? Path.GetFullPath(path.ToString())
                : null;
        }
        finally
        {
            CloseHandle(process);
        }
    }

    private static void Log(Exception error)
    {
        try
        {
            string logDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CopilotKeyBridge");
            Directory.CreateDirectory(logDirectory);
            string logPath = Path.Combine(logDirectory, "CopilotKeyBridge.log");
            File.AppendAllText(
                logPath,
                DateTime.Now.ToString("s") + " " + error + Environment.NewLine,
                Encoding.UTF8);
        }
        catch
        {
        }
    }
}
