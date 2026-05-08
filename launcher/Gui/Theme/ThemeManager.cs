using System;
using Microsoft.Win32;

namespace Tiny11Options.Launcher.Gui.Theme;

public class ThemeManager
{
    public event EventHandler<string>? ThemeChanged;

    private string _userPreference;
    private readonly Func<bool> _systemPrefersDark;

    public ThemeManager(string userPreference = "system", Func<bool>? systemPrefersDark = null)
    {
        _userPreference = userPreference;
        _systemPrefersDark = systemPrefersDark ?? DetectSystemDarkMode;
    }

    public string UserPreference => _userPreference;

    public void SetUserPreference(string pref)
    {
        if (pref != "system" && pref != "light" && pref != "dark") return;
        _userPreference = pref;
        ThemeChanged?.Invoke(this, EffectiveTheme());
    }

    public string EffectiveTheme()
    {
        if (_userPreference == "system")
            return _systemPrefersDark() ? "dark" : "light";
        return _userPreference;
    }

    private static bool DetectSystemDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var v = key?.GetValue("AppsUseLightTheme");
            if (v is int i) return i == 0;
        }
        catch { }
        return false;
    }
}
