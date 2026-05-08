using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Tiny11Options.Launcher.Gui.Bridge;
using Tiny11Options.Launcher.Gui.Settings;
using Tiny11Options.Launcher.Gui.Theme;

namespace Tiny11Options.Launcher.Gui.Handlers;

public class ThemeHandlers : IBridgeHandler
{
    private readonly ThemeManager _theme;
    private readonly UserSettings _settings;

    public ThemeHandlers(ThemeManager theme, UserSettings settings)
    {
        _theme = theme;
        _settings = settings;
    }

    public IEnumerable<string> HandledTypes => new[] { "get-theme", "apply-theme" };

    public Task<BridgeMessage?> HandleAsync(string type, JsonObject? payload)
    {
        if (type == "apply-theme")
        {
            var pref = payload?["theme"]?.ToString() ?? "system";
            _theme.SetUserPreference(pref);
            _settings.Theme = pref;
            _settings.Save();
        }

        var resp = new BridgeMessage
        {
            Type = "theme-applied",
            Payload = new JsonObject
            {
                ["userPreference"] = _theme.UserPreference,
                ["effective"] = _theme.EffectiveTheme(),
            },
        };
        return Task.FromResult<BridgeMessage?>(resp);
    }
}
