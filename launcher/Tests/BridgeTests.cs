using System;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Moq;
using Tiny11Options.Launcher.Gui.Bridge;
using Xunit;

namespace Tiny11Options.Launcher.Tests;

public class BridgeTests
{
    [Fact]
    public async Task Dispatch_RoutesToHandler_ByType()
    {
        var handler = new Mock<IBridgeHandler>();
        handler.Setup(h => h.HandledTypes).Returns(new[] { "ping" });
        handler.Setup(h => h.HandleAsync("ping", It.IsAny<JsonObject>()))
            .ReturnsAsync(new BridgeMessage { Type = "pong", Payload = new JsonObject() });

        var bridge = new Bridge(new[] { handler.Object });

        var resp = await bridge.DispatchJsonAsync("{\"type\":\"ping\",\"payload\":{}}");

        Assert.NotNull(resp);
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("pong", typeProp);
    }

    [Fact]
    public async Task Dispatch_ReturnsHandlerError_OnUnknownType()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{\"type\":\"unknown\"}");
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("handler-error", typeProp);
    }

    [Fact]
    public async Task Dispatch_ReturnsHandlerError_OnMalformedJson()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{ not valid");
        var typeProp = JsonNode.Parse(resp!)?["type"]?.ToString();
        Assert.Equal("handler-error", typeProp);
    }

    [Fact]
    public async Task Dispatch_HandlerError_EchoesRequestType_OnUnknownType()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{\"type\":\"validate-iso\",\"payload\":{}}");

        Assert.NotNull(resp);
        var doc = JsonNode.Parse(resp!);
        Assert.Equal("handler-error", doc!["type"]?.ToString());
        Assert.Equal("validate-iso", doc["payload"]?["requestType"]?.ToString());
    }

    [Fact]
    public async Task Dispatch_HandlerError_EchoesRequestType_OnHandlerThrow()
    {
        var handler = new Mock<IBridgeHandler>();
        handler.Setup(h => h.HandledTypes).Returns(new[] { "start-build" });
        handler.Setup(h => h.HandleAsync("start-build", It.IsAny<JsonObject>()))
            .ThrowsAsync(new InvalidOperationException("boom"));

        var bridge = new Bridge(new[] { handler.Object });
        var resp = await bridge.DispatchJsonAsync("{\"type\":\"start-build\",\"payload\":{}}");

        Assert.NotNull(resp);
        var doc = JsonNode.Parse(resp!);
        Assert.Equal("handler-error", doc!["type"]?.ToString());
        Assert.Equal("start-build", doc["payload"]?["requestType"]?.ToString());
    }

    [Fact]
    public async Task Dispatch_HandlerError_OmitsRequestType_OnMalformedJson()
    {
        var bridge = new Bridge(Array.Empty<IBridgeHandler>());
        var resp = await bridge.DispatchJsonAsync("{ not valid");

        Assert.NotNull(resp);
        var doc = JsonNode.Parse(resp!);
        Assert.Equal("handler-error", doc!["type"]?.ToString());
        // requestType should be absent (or null) since the bridge couldn't parse the message.
        Assert.Null(doc["payload"]?["requestType"]);
    }
}
