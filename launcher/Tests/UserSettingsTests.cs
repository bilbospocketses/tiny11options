using System;
using System.IO;
using System.Text.Json;
using Tiny11Options.Launcher.Gui.Settings;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class UserSettingsTests
{
    private static string TempPath() =>
        Path.Combine(Path.GetTempPath(), $"tiny11-settings-{Guid.NewGuid():N}.json");

    [Fact]
    public void Load_ReturnsDefaults_WhenFileMissing()
    {
        var path = TempPath();
        var s = UserSettings.Load(path);
        Assert.NotNull(s);
        Assert.Equal(1200, s.WindowWidth);
        Assert.Equal(900, s.WindowHeight);
    }

    [Fact]
    public void Save_ThenLoad_RoundTrips()
    {
        var path = TempPath();
        try
        {
            var original = new UserSettings { WindowWidth = 1500, WindowHeight = 1000, Theme = "dark" };
            original.Save(path);

            var loaded = UserSettings.Load(path);
            Assert.Equal(1500, loaded.WindowWidth);
            Assert.Equal(1000, loaded.WindowHeight);
            Assert.Equal("dark", loaded.Theme);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void Load_ReturnsDefaults_WhenJsonCorrupt()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, "{ corrupt json");
            var s = UserSettings.Load(path);
            Assert.Equal(1200, s.WindowWidth);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void LastProfilePath_RoundTrips()
    {
        var path = TempPath();
        try
        {
            var original = new UserSettings { LastProfilePath = "C:\\foo\\bar.json" };
            original.Save(path);

            var loaded = UserSettings.Load(path);
            Assert.Equal("C:\\foo\\bar.json", loaded.LastProfilePath);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void LastProfilePath_DefaultsToEmpty_WhenFileMissing()
    {
        var path = TempPath();
        var s = UserSettings.Load(path);
        Assert.Equal("", s.LastProfilePath);
    }

    [Fact]
    public void Load_ClampsBelowMinimumWindowSize()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(new { WindowWidth = 200, WindowHeight = 200 }));
            var s = UserSettings.Load(path);
            Assert.True(s.WindowWidth >= 1000);
            Assert.True(s.WindowHeight >= 750);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}
