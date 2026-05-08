using System;
using System.IO;
using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Theme;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class ThemeHandlersTests
{
    [Fact]
    public async Task ApplyTheme_PersistsToSettings()
    {
        var path = Path.Combine(Path.GetTempPath(), $"theme-{Guid.NewGuid():N}.json");
        try
        {
            var s = new UserSettings();
            var t = new ThemeManager("system", () => false);
            var h = new ThemeHandlers(t, s);

            await h.HandleAsync("apply-theme", JsonNode.Parse("{\"theme\":\"dark\"}")!.AsObject());
            s.Save(path);

            var reloaded = UserSettings.Load(path);
            Assert.Equal("dark", reloaded.Theme);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task GetTheme_ReturnsEffectiveTheme()
    {
        var t = new ThemeManager("dark", () => false);
        var h = new ThemeHandlers(t, new UserSettings());
        var resp = await h.HandleAsync("get-theme", new JsonObject());
        Assert.Equal("dark", resp!.Payload!["effective"]?.ToString());
    }
}
