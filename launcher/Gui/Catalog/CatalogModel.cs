using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Tiny11Options.Launcher.Gui.Catalog;

public class CatalogItem
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("default")] public bool Default { get; set; }
    [JsonPropertyName("locked")] public bool Locked { get; set; }
    [JsonPropertyName("runtimeDepsOn")] public List<string>? RuntimeDepsOn { get; set; }
}

public class Catalog
{
    [JsonPropertyName("items")] public List<CatalogItem> Items { get; set; } = new();
}
