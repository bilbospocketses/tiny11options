using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class TitleBarThemeHandlersTests
{
    [Fact]
    public void HandledTypes_ContainsThemeChanged()
    {
        var h = new TitleBarThemeHandlers(_ => { });
        Assert.Contains("theme-changed", h.HandledTypes);
    }

    [Fact]
    public async Task HandleAsync_DarkPayload_InvokesCallbackWithTrue()
    {
        bool? captured = null;
        var h = new TitleBarThemeHandlers(b => captured = b);
        var payload = new JsonObject { ["theme"] = "dark" };

        var resp = await h.HandleAsync("theme-changed", payload);

        Assert.Null(resp); // one-way notification, no response expected
        Assert.True(captured);
    }

    [Fact]
    public async Task HandleAsync_LightPayload_InvokesCallbackWithFalse()
    {
        bool? captured = null;
        var h = new TitleBarThemeHandlers(b => captured = b);
        var payload = new JsonObject { ["theme"] = "light" };

        await h.HandleAsync("theme-changed", payload);

        Assert.False(captured);
    }

    [Fact]
    public async Task HandleAsync_NullPayload_InvokesCallbackWithFalse()
    {
        // Defensive: a malformed message with no payload shouldn't throw — fall back to light (false).
        bool? captured = null;
        var h = new TitleBarThemeHandlers(b => captured = b);

        await h.HandleAsync("theme-changed", null);

        Assert.False(captured);
    }

    [Fact]
    public async Task HandleAsync_UnknownThemeValue_InvokesCallbackWithFalse()
    {
        // Anything other than literal "dark" treats as light — explicit safety against
        // future enum additions ("system", "auto") that would otherwise silently fall through.
        bool? captured = null;
        var h = new TitleBarThemeHandlers(b => captured = b);
        var payload = new JsonObject { ["theme"] = "system" };

        await h.HandleAsync("theme-changed", payload);

        Assert.False(captured);
    }
}
