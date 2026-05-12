using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace Tiny11Options.Launcher.Gui.Theme;

/// <summary>
/// Applies dark/light theming to a WPF window's Windows-managed title bar
/// (the non-client area that CSS / WPF chrome customization can't reach).
///
/// Uses the DWM (Desktop Window Manager) attribute DWMWA_USE_IMMERSIVE_DARK_MODE.
/// Win10 1809-19041 exposed it as attribute id 19; Win10 19041+ and Win11 use 20.
/// Both attribute ids are unrecognized as a no-op on the wrong build, so we call
/// both — whichever the OS recognizes takes effect; the other is silently ignored.
///
/// Pre-1809 Windows 10 builds and earlier OSes don't support this at all; the
/// call returns a non-zero HRESULT and the title bar stays at system default.
/// Acceptable graceful degradation — we don't surface the failure.
/// </summary>
public static class TitleBarThemeApplier
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE             = 20;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int valueSize);

    /// <summary>
    /// Apply dark or light title-bar theming to <paramref name="window"/>. Safe to call
    /// before the window handle exists — the call is skipped and the caller can re-invoke
    /// once <see cref="WindowInteropHelper.EnsureHandle"/> has run (typically inside the
    /// Loaded event).
    /// </summary>
    public static void Apply(Window window, bool isDark)
    {
        if (window is null) return;
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;

        int flag = isDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref flag, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref flag, sizeof(int));
    }

    /// <summary>
    /// Reads the system-level "apps use light theme" setting from the user-scope
    /// Personalize key. Returns true if the system is configured for dark mode.
    /// Used to pick an initial title-bar theme at window-load time before JS has
    /// booted and reported the in-app theme via the bridge.
    /// Missing / unreadable key returns false (= light), matching the OS default.
    /// </summary>
    public static bool IsSystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key is null) return false;
            var value = key.GetValue("AppsUseLightTheme");
            if (value is int i) return i == 0;
        }
        catch { /* registry unreadable — fall through to false */ }
        return false;
    }
}
