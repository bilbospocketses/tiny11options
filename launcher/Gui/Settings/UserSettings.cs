using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Settings;

public class UserSettings
{
    public const int MinWidth = 1000;
    public const int MinHeight = 750;

    public int WindowWidth { get; set; } = 1200;
    public int WindowHeight { get; set; } = 900;
    public string Theme { get; set; } = "system";

    /// Last full path the user saved or loaded a profile from. Used by BrowseHandlers
    /// to set the initial directory of profile-save / profile-load dialogs so the
    /// user lands where they last worked. Empty string = never persisted; falls
    /// back to MyDocuments. PORTED: tiny11maker.ps1:225 (legacy initial-dir was
    /// <repo>/config/examples; not portable to Path C since the dir isn't extracted,
    /// so we track per-user state instead — strictly an upgrade in UX).
    public string LastProfilePath { get; set; } = "";

    [JsonIgnore]
    public static string DefaultPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "tiny11options", "settings.json");

    public static UserSettings Load(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return new UserSettings();

        try
        {
            var json = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<UserSettings>(json);
            if (loaded is null) return new UserSettings();
            loaded.Clamp();
            return loaded;
        }
        catch
        {
            return new UserSettings();
        }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    private void Clamp()
    {
        if (WindowWidth < MinWidth) WindowWidth = MinWidth;
        if (WindowHeight < MinHeight) WindowHeight = MinHeight;
        if (Theme != "system" && Theme != "light" && Theme != "dark") Theme = "system";
    }
}
