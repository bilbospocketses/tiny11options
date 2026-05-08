using Tiny11Options.Launcher.Gui.Theme;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ThemeManagerTests
{
    [Fact]
    public void EffectiveTheme_FollowsSystem_WhenUserPrefIsSystem()
    {
        var mgr = new ThemeManager(userPreference: "system", systemPrefersDark: () => true);
        Assert.Equal("dark", mgr.EffectiveTheme());

        mgr = new ThemeManager(userPreference: "system", systemPrefersDark: () => false);
        Assert.Equal("light", mgr.EffectiveTheme());
    }

    [Fact]
    public void EffectiveTheme_OverridesSystem_WhenUserSpecifies()
    {
        var mgr = new ThemeManager(userPreference: "dark", systemPrefersDark: () => false);
        Assert.Equal("dark", mgr.EffectiveTheme());

        mgr = new ThemeManager(userPreference: "light", systemPrefersDark: () => true);
        Assert.Equal("light", mgr.EffectiveTheme());
    }

    [Fact]
    public void SetUserPreference_FiresChangeEvent()
    {
        var mgr = new ThemeManager(userPreference: "light", systemPrefersDark: () => false);
        var fired = false;
        string? captured = null;
        mgr.ThemeChanged += (_, t) => { fired = true; captured = t; };

        mgr.SetUserPreference("dark");

        Assert.True(fired);
        Assert.Equal("dark", captured);
    }
}
