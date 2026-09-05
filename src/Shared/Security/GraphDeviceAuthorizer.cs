using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace LogCollector.Shared.Security;

/// <summary>Checks tenant membership using the frontend identity's Microsoft Graph tenant.</summary>
public sealed class GraphDeviceAuthorizer(TokenCredential credential, HttpClient http)
{
    public async Task<bool> IsEnabledTenantDeviceAsync(string boundDeviceId, CancellationToken ct)
    {
        if (!Guid.TryParse(boundDeviceId, out var deviceId))
            return false;

        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://graph.microsoft.com/.default"]), ct);
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://graph.microsoft.com/v1.0/devices(deviceId='{deviceId:D}')?$select=deviceId,accountEnabled");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await http.SendAsync(request, ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        // Outages and missing application consent are not an authorization success.
        // Propagate these failures so intake fails and the client retains its spool.
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var root = document.RootElement;
        return root.TryGetProperty("deviceId", out var actual)
            && actual.ValueKind == JsonValueKind.String
            && Guid.TryParse(actual.GetString(), out var actualId)
            && actualId == deviceId
            && root.TryGetProperty("accountEnabled", out var enabled)
            && enabled.ValueKind == JsonValueKind.True;
    }
}
