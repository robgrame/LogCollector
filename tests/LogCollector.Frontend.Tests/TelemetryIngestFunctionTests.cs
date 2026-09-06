using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LogCollector.Frontend.Functions;
using LogCollector.Shared.Models;
using LogCollector.Shared.Security;
using LogCollector.Shared.Tests;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Xunit;

namespace LogCollector.Frontend.Tests;

public sealed class TelemetryIngestFunctionTests
{
    public static TheoryData<bool, string, string> PurposeCases
    {
        get
        {
            var cases = new TheoryData<bool, string, string>();
            foreach (var legacy in new[] { false, true })
            foreach (var version in new[] { "LOGCOLLECTOR-TELEMETRY-V1", "LOGCOLLECTOR-INVENTORY-V1" })
            foreach (var table in new[] { "RemediationResults_CL", "HealthChecks_CL" })
                cases.Add(legacy, version, table);
            return cases;
        }
    }

    [Theory]
    [MemberData(nameof(PurposeCases))]
    public async Task BothRoutesAcceptUnrelatedPurposesWithoutChangingSignedBytes(
        bool legacy, string version, string table)
    {
        using var h = new FrontendTestHarness();
        var body = Body(table, version);

        var result = await h.Invoke(legacy, h.Request(legacy, body));

        AssertPublished(h, result, body, table, "EnterprisePki");
        Assert.Equal(0, h.Graph.Calls);
    }

    [Fact]
    public async Task LegacyInventoryClientStillPublishesItsOriginalEnvelope()
    {
        using var h = new FrontendTestHarness();
        var body = Body("InventoryWindows_CL", "LOGCOLLECTOR-INVENTORY-V1",
            records: """[{"RecordType":"OperatingSystem","Caption":"Windows 11","BuildNumber":"26100"}]""");

        var result = await h.Invoke(true, h.Request(true, body));

        AssertPublished(h, result, body, "InventoryWindows_CL", "EnterprisePki");
    }

    [Theory]
    [InlineData(false, "../HealthChecks_CL", "unsupported characters")]
    [InlineData(true, "../HealthChecks_CL", "unsupported characters")]
    [InlineData(false, "UnmappedPurpose_CL", "not an accepted ingestion target")]
    [InlineData(true, "UnmappedPurpose_CL", "not an accepted ingestion target")]
    [InlineData(false, "", "tableName is required")]
    [InlineData(true, "", "tableName is required")]
    public async Task InvalidOrUnmappedTableNeverPublishes(bool legacy, string table, string reason)
    {
        using var h = new FrontendTestHarness();
        var result = await h.Invoke(legacy, h.Request(legacy, Body(table)));

        AssertDenied(result, 400, reason);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SignatureForOtherRouteIsRejectedBeforeNonceReservation(bool legacy)
    {
        using var h = new FrontendTestHarness();
        var result = await h.Invoke(legacy, h.Request(legacy, Body(),
            signedPath: legacy ? "/api/submit" : "/api/inventory"));

        AssertDenied(result, 401, "signature");
        Assert.Equal(0, h.Nonces.Count);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SameNonceIsRejectedAcrossRoutesEvenWithCorrectNewRouteSignature(bool firstLegacy)
    {
        using var h = new FrontendTestHarness();
        var nonce = Guid.NewGuid();
        var body = Body();
        var first = await h.Invoke(firstLegacy, h.Request(firstLegacy, body, nonce: nonce));
        AssertPublished(h, first, body, "HealthChecks_CL", "EnterprisePki");

        var replay = await h.Invoke(!firstLegacy, h.Request(!firstLegacy, body, nonce: nonce));

        AssertDenied(replay, 409, "replay");
        Assert.Single(h.Blobs.Uploads);
        Assert.Single(h.ServiceBus.Messages);
        Assert.Single(h.ServiceBus.Queues);
        Assert.Equal(1, h.Nonces.Count);
        Assert.Equal(new[] { "container", "blob", "send" }, h.Events);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SemanticallyIdenticalButReserializedBodyFailsSignature(bool legacy)
    {
        using var h = new FrontendTestHarness();
        var signedBody = Body();
        using var parsed = JsonDocument.Parse(signedBody);
        var compactBody = JsonSerializer.SerializeToUtf8Bytes(parsed.RootElement);
        Assert.NotEqual(Encoding.UTF8.GetString(signedBody), Encoding.UTF8.GetString(compactBody));

        var result = await h.Invoke(legacy, h.Request(legacy, compactBody, signedBody: signedBody));

        AssertDenied(result, 401, "signature");
        Assert.Equal(0, h.Nonces.Count);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task CertificateMustBeBoundToSubmittedDevice(bool legacy, bool intune)
    {
        using var h = new FrontendTestHarness(intune: intune);
        var result = await h.Invoke(legacy,
            h.Request(legacy, Body(deviceId: FrontendTestHarness.OtherDeviceId)));

        AssertDenied(result, 403, "not bound to the submitted device");
        Assert.Equal(0, h.Graph.Calls);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingPkiBindingClaimIsDenied(bool legacy)
    {
        using var h = new FrontendTestHarness(boundDeviceId: null);
        var result = await h.Invoke(legacy, h.Request(legacy, Body()));

        AssertDenied(result, 401, "missing the configured device-id binding claim");
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingCertificateIsDenied(bool legacy)
    {
        using var h = new FrontendTestHarness();
        var request = h.Request(legacy, Body());
        request.HttpContext.Connection.ClientCertificate = null;

        AssertDenied(await h.Invoke(legacy, request), 401, "client cert");
        Assert.Equal(0, h.Nonces.Count);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ValidSignatureDoesNotBypassUntrustedPkiChain(bool legacy)
    {
        using var h = new FrontendTestHarness();
        using var foreignRoot = TestCertificates.CreateRootCa("Untrusted Frontend CA");
        using var foreignLeaf = TestCertificates.CreateClientCertificate(
            foreignRoot, "device-01", sanUriDeviceId: FrontendTestHarness.DeviceId);
        using var foreignPublic = TestCertificates.PublicOnly(foreignLeaf);
        var request = h.Request(legacy, Body(), signingCertificate: foreignLeaf);
        request.HttpContext.Connection.ClientCertificate = foreignPublic;

        AssertDenied(await h.Invoke(legacy, request), 401, "client cert");
        Assert.Equal(0, h.Nonces.Count);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task IntuneCertificateRequiresEnabledTenantDeviceBeforePublication(bool legacy)
    {
        using var h = new FrontendTestHarness(intune: true);
        var body = Body(version: legacy ? "LOGCOLLECTOR-INVENTORY-V1" : "LOGCOLLECTOR-TELEMETRY-V1");

        var result = await h.Invoke(legacy, h.Request(legacy, body));

        AssertPublished(h, result, body, "HealthChecks_CL", "IntuneEnrollment");
        Assert.Equal(1, h.Graph.Calls);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task DisabledOrAbsentIntuneTenantDeviceIsDenied(bool legacy, bool absent)
    {
        using var h = new FrontendTestHarness(intune: true);
        h.Graph.Status = absent ? HttpStatusCode.NotFound : HttpStatusCode.OK;
        h.Graph.Body = $$"""{"deviceId":"{{FrontendTestHarness.DeviceId}}","accountEnabled":false}""";

        AssertDenied(await h.Invoke(legacy, h.Request(legacy, Body())),
            403, "device is not authorized in this tenant");
        Assert.Equal(1, h.Graph.Calls);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task GraphOutageDoesNotBecomeAnAuthorizationSuccess(bool legacy)
    {
        using var h = new FrontendTestHarness(intune: true);
        h.Graph.Status = HttpStatusCode.ServiceUnavailable;

        var exception = await Assert.ThrowsAsync<HttpRequestException>(
            () => h.Invoke(legacy, h.Request(legacy, Body())));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, exception.StatusCode);
        Assert.Equal(1, h.Graph.Calls);
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnknownEnvelopeVersionIsDenied(bool legacy)
    {
        using var h = new FrontendTestHarness();
        AssertDenied(await h.Invoke(legacy, h.Request(legacy, Body(version: "UNKNOWN-V1"))),
            400, "unsupported envelopeVersion");
        h.AssertNoPublication();
    }

    [Theory]
    [InlineData(nameof(TelemetryIngestFunction.Run), "SubmitTelemetry", "submit")]
    [InlineData(nameof(TelemetryIngestFunction.RunLegacy), "SubmitLegacyInventory", "inventory")]
    public void FunctionMetadataPreservesPublicRoutes(string methodName, string functionName, string route)
    {
        var method = typeof(TelemetryIngestFunction).GetMethod(methodName)!;
        Assert.Equal(functionName, method.GetCustomAttribute<FunctionAttribute>()!.Name);
        var trigger = method.GetParameters()[0].GetCustomAttribute<HttpTriggerAttribute>()!;
        Assert.Equal(route, trigger.Route);
        Assert.NotNull(trigger.Methods);
        Assert.Equal("post", Assert.Single(trigger.Methods));
        Assert.Equal(AuthorizationLevel.Anonymous, trigger.AuthLevel);
    }

    internal static byte[] Body(
        string table = "HealthChecks_CL",
        string version = "LOGCOLLECTOR-TELEMETRY-V1",
        string deviceId = FrontendTestHarness.DeviceId,
        string? records = null)
    {
        records ??= table == "RemediationResults_CL"
            ? """[{"RemediationId":"repair-service","ExitCode":0,"Changed":true,"Details":{"Before":"stopped","After":"running"}}]"""
            : """[{"Check":"disk","Healthy":true,"FreeBytes":1234567890123,"Samples":[1,2.50,null],"Note":"caf\u00e9"}]""";
        return Encoding.UTF8.GetBytes($$"""
            {
              "envelopeVersion" : "{{version}}",
              "tableName" : "{{table}}",
              "entraDeviceId" : "{{deviceId}}",
              "deviceName" : "device-01",
              "source" : "PurposeIndependentAgent",
              "collectedAtUtc" : "2026-09-01T12:34:56Z",
              "properties" : {"run":"nightly"},
              "records" : {{records}}
            }

            """);
    }

    internal static void AssertPublished(
        FrontendTestHarness h, IActionResult result, byte[] body, string table, string trustTier)
    {
        var response = Assert.IsType<ObjectResult>(result);
        Assert.Equal(202, response.StatusCode);
        var accepted = JsonSerializer.SerializeToElement(response.Value);
        Assert.Equal("accepted", accepted.GetProperty("status").GetString());
        Assert.Equal(table, accepted.GetProperty("tableName").GetString());
        Assert.Equal(1, accepted.GetProperty("recordCount").GetInt32());
        Assert.Equal(trustTier, accepted.GetProperty("trustTier").GetString());

        var upload = Assert.Single(h.Blobs.Uploads);
        Assert.Equal(body, upload.Body);
        Assert.Equal("application/json", upload.Headers["x-ms-blob-content-type"]);
        Assert.Equal("*", upload.Headers["If-None-Match"]);
        var message = Assert.Single(h.ServiceBus.Messages);
        var pointer = JsonSerializer.Deserialize<QueuedIngestionMessage>(message.Body.ToArray())!;
        Assert.True(pointer.Validate().Ok, pointer.Validate().Reason);
        var submissionId = Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant();
        Assert.Equal(submissionId, pointer.CorrelationId);
        Assert.Equal(submissionId, accepted.GetProperty("correlationId").GetString());
        Assert.Equal(table, pointer.TableName);
        Assert.Equal(FrontendTestHarness.ContainerName, pointer.ContainerName);
        Assert.Equal($"{table}/{submissionId}.json", pointer.BlobName);
        Assert.Equal($"/{pointer.ContainerName}/{pointer.BlobName}", upload.Uri.AbsolutePath);
        Assert.Equal(body.LongLength, pointer.PayloadBytes);
        Assert.Equal(Convert.ToBase64String(SHA256.HashData(body)), pointer.PayloadSha256);
        Assert.Equal(FrontendTestHarness.DeviceId, pointer.EntraDeviceId);
        Assert.Equal("device-01", pointer.DeviceName);
        Assert.Equal("PurposeIndependentAgent", pointer.Source);
        Assert.Equal(DateTimeOffset.Parse("2026-09-01T12:34:56Z"), pointer.CollectedAtUtc);
        Assert.Equal(h.Leaf.Thumbprint, pointer.CertificateThumbprint);
        Assert.Equal(submissionId, upload.Headers["x-ms-meta-correlationId"]);
        Assert.Equal(table, upload.Headers["x-ms-meta-tableName"]);
        Assert.Equal(FrontendTestHarness.DeviceId, upload.Headers["x-ms-meta-entraDeviceId"]);
        Assert.Equal(table, message.Subject);
        Assert.Equal("application/json", message.ContentType);
        Assert.Equal(submissionId, message.CorrelationId);
        Assert.Equal(submissionId, message.MessageId);
        using var pointerJson = JsonDocument.Parse(message.Body.ToArray());
        Assert.False(pointerJson.RootElement.TryGetProperty("records", out _));
        Assert.Equal(new[] { "container", "blob", "send" }, h.Events);
    }

    private static void AssertDenied(IActionResult result, int status, string reason)
    {
        var response = Assert.IsType<ObjectResult>(result);
        Assert.Equal(status, response.StatusCode);
        var body = JsonSerializer.SerializeToElement(response.Value);
        Assert.Equal("denied", body.GetProperty("status").GetString());
        Assert.Contains(reason, body.GetProperty("message").GetString());
    }
}
