using System.Text.Json.Nodes;
using Tiny11Options.Launcher.Gui.Handlers;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class SelectionHandlersTests
{
    private const string SimpleCatalog = """
        {
          "items": [
            {"id":"a","displayName":"A","default":true,"locked":false},
            {"id":"b","displayName":"B","default":false,"locked":false,"runtimeDepsOn":["a"]},
            {"id":"c","displayName":"C","default":true,"locked":true}
          ]
        }
        """;

    [Fact]
    public async Task Reconcile_AddsRuntimeDeps()
    {
        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{SimpleCatalog},\"selected\":[\"b\"]}}")!.AsObject());

        Assert.Equal("selections-reconciled", resp!.Type);
        var effective = resp.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "a");
        Assert.Contains(effective!, n => n!.ToString() == "b");
    }

    [Fact]
    public async Task Reconcile_LockedItemsAlwaysIncluded()
    {
        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{SimpleCatalog},\"selected\":[]}}")!.AsObject());

        var effective = resp!.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "c");
    }

    [Fact]
    public async Task Reconcile_TransitiveRuntimeDeps()
    {
        // a -> b -> c chain: selecting c should pull in a and b
        const string chainCatalog = """
            {
              "items": [
                {"id":"a","displayName":"A","default":false,"locked":false},
                {"id":"b","displayName":"B","default":false,"locked":false,"runtimeDepsOn":["a"]},
                {"id":"c","displayName":"C","default":false,"locked":false,"runtimeDepsOn":["b"]}
              ]
            }
            """;

        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{chainCatalog},\"selected\":[\"c\"]}}")!.AsObject());

        var effective = resp!.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "a");
        Assert.Contains(effective!, n => n!.ToString() == "b");
        Assert.Contains(effective!, n => n!.ToString() == "c");
    }

    [Fact]
    public async Task Reconcile_CycleInRuntimeDepsDoesNotHang()
    {
        // a -> b -> a cycle: iterative loop must terminate because Add returns false once present
        const string cycleCatalog = """
            {
              "items": [
                {"id":"a","displayName":"A","default":false,"locked":false,"runtimeDepsOn":["b"]},
                {"id":"b","displayName":"B","default":false,"locked":false,"runtimeDepsOn":["a"]}
              ]
            }
            """;

        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{cycleCatalog},\"selected\":[\"a\"]}}")!.AsObject());

        Assert.Equal("selections-reconciled", resp!.Type);
        var effective = resp.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "a");
        Assert.Contains(effective!, n => n!.ToString() == "b");
    }

    [Fact]
    public async Task Reconcile_MissingCatalogReturnsError()
    {
        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse("{\"selected\":[]}")!.AsObject());

        Assert.Equal("handler-error", resp!.Type);
    }

    [Fact]
    public async Task Reconcile_DepNotInCatalogIsIncludedWithoutError()
    {
        // runtimeDepsOn references an id not in the catalog items; should silently include the
        // unknown id in effective (it gets added to selected, just has no further deps to expand)
        const string unknownDepCatalog = """
            {
              "items": [
                {"id":"a","displayName":"A","default":false,"locked":false,"runtimeDepsOn":["ghost"]}
              ]
            }
            """;

        var handler = new SelectionHandlers();
        var resp = await handler.HandleAsync("reconcile-selections",
            JsonNode.Parse($"{{\"catalog\":{unknownDepCatalog},\"selected\":[\"a\"]}}")!.AsObject());

        Assert.Equal("selections-reconciled", resp!.Type);
        var effective = resp.Payload!["effective"]?.AsArray();
        Assert.Contains(effective!, n => n!.ToString() == "ghost");
    }
}
