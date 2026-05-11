using System;
using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;

namespace Tiny11Options.Launcher.Gui.Handlers;

/// <summary>
/// Bridge handler for the `theme-changed` message. JS owns the theme model
/// (localStorage + data-theme attribute, see ui/app.js initTheme + toggle); this
/// handler exists ONLY to propagate the current theme to the Windows-managed
/// title bar via DWM. Without it, the title bar stays at the OS default and looks
/// jarring against a dark in-app theme.
///
/// Takes an Action&lt;bool&gt; rather than a Window directly so xUnit can inject a
/// recording callback without needing an STA WPF dispatcher. Production wiring
/// (MainWindow.BuildBridge) supplies a callback that marshals to the UI thread
/// and calls TitleBarThemeApplier.Apply.
///
/// Note this is NOT a re-introduction of the old apply-theme/get-theme handlers
/// deleted in the Phase 4.5 audit (2026-05-08) — those were dead-code C# theme
/// ownership. This handler responds to a one-way JS-to-C# notification for chrome
/// rendering only, never returns a value to JS, and doesn't persist anything.
/// </summary>
public sealed class TitleBarThemeHandlers : IBridgeHandler
{
    private readonly Action<bool> _applyDark;

    public TitleBarThemeHandlers(Action<bool> applyDark) { _applyDark = applyDark; }

    public IEnumerable<string> HandledTypes => new[] { "theme-changed" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        var theme = payload?["theme"]?.GetValue<string>();
        _applyDark(theme == "dark");
        // One-way notification — no response payload.
        return Task.FromResult<BridgeMessage?>(null);
    }
}
