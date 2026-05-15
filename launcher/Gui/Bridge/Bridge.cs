using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Tiny11Options.Launcher.Gui.Bridge;

public class Bridge
{
    private readonly Dictionary<string, IBridgeHandler> _handlers = new(StringComparer.OrdinalIgnoreCase);

    public Bridge(IEnumerable<IBridgeHandler> handlers)
    {
        foreach (var h in handlers) Register(h);
    }

    /// Register a handler after construction. Needed when handlers and Bridge
    /// have a circular dependency (e.g. BuildHandlers needs Bridge for SendToJs).
    public void Register(IBridgeHandler handler)
    {
        foreach (var t in handler.HandledTypes) _handlers[t] = handler;
    }

    public event Action<string>? MessageToJs;

    public async Task<string?> DispatchJsonAsync(string json)
    {
        BridgeMessage? msg;
        try
        {
            msg = JsonSerializer.Deserialize<BridgeMessage>(json);
            if (msg is null || string.IsNullOrEmpty(msg.Type))
                return ErrorResponse("Empty or null bridge message");
        }
        catch (JsonException ex)
        {
            return ErrorResponse($"Malformed JSON: {ex.Message}");
        }

        if (!_handlers.TryGetValue(msg.Type, out var handler))
            return ErrorResponse($"Unknown message type: {msg.Type}", msg.Type);

        try
        {
            var resp = await handler.HandleAsync(msg.Type, msg.Payload);
            return resp is null ? null : Serialize(resp);
        }
        catch (Exception ex)
        {
            return ErrorResponse($"Handler {msg.Type} threw: {ex.Message}", msg.Type);
        }
    }

    public void SendToJs(BridgeMessage msg)
    {
        MessageToJs?.Invoke(Serialize(msg));
    }

    private static string Serialize(BridgeMessage msg)
        => JsonSerializer.Serialize(msg);

    private static string ErrorResponse(string msg, string? requestType = null)
    {
        var obj = new JsonObject { ["message"] = msg };
        // v1.0.8 audit WARNING launcher B4: echo the original request type so
        // JS state machines can route by request type, not by substring-matching
        // the error message. Null/empty when the bridge couldn't determine the
        // type (malformed JSON, missing/empty type field).
        if (!string.IsNullOrEmpty(requestType))
        {
            obj["requestType"] = requestType;
        }
        return JsonSerializer.Serialize(new BridgeMessage { Type = "handler-error", Payload = obj });
    }
}
