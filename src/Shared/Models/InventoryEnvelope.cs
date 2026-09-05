using System.Text.Json;
using System.Text.Json.Serialization;

namespace LogCollector.Shared.Models;

/// <summary>
/// The signed request body posted by the Windows inventory client.
/// </summary>
/// <remarks>
/// The envelope is <b>not</b> an authentication source. Every field on it is
/// attacker-controlled until the frontend has (a) validated the mTLS client
/// certificate chain, (b) verified the IDA-SIGNATURE-V1 body signature made
/// with that certificate's private key, and (c) proven that
/// <see cref="EntraDeviceId"/> equals the device id the certificate is bound to.
/// </remarks>
public sealed class InventoryEnvelope
{
    /// <summary>Envelope schema version. Only <see cref="CurrentVersion"/> is accepted.</summary>
    public const string CurrentVersion = "LOGCOLLECTOR-INVENTORY-V1";

    [JsonPropertyName("envelopeVersion")]
    public string EnvelopeVersion { get; set; } = CurrentVersion;

    /// <summary>Target Log Analytics custom table, e.g. <c>InventoryWindows_CL</c>.</summary>
    [JsonPropertyName("tableName")]
    public string? TableName { get; set; }

    /// <summary>Entra (Azure AD) device id GUID reported by the client.</summary>
    [JsonPropertyName("entraDeviceId")]
    public string? EntraDeviceId { get; set; }

    /// <summary>Local machine name. Diagnostic only — never used for authorization.</summary>
    [JsonPropertyName("deviceName")]
    public string? DeviceName { get; set; }

    /// <summary>Intune enrollment id. Diagnostic only — never used for authorization.</summary>
    [JsonPropertyName("intuneDeviceId")]
    public string? IntuneDeviceId { get; set; }

    /// <summary>Client-generated correlation id. Regenerated server-side when absent or malformed.</summary>
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; set; }

    /// <summary>Origin of the sample, e.g. <c>WindowsScheduledTask</c>.</summary>
    [JsonPropertyName("source")]
    public string? Source { get; set; }

    /// <summary>UTC instant the inventory was collected on the device.</summary>
    [JsonPropertyName("collectedAtUtc")]
    public DateTimeOffset? CollectedAtUtc { get; set; }

    /// <summary>Small string-valued annotations copied onto every emitted row.</summary>
    [JsonPropertyName("properties")]
    public Dictionary<string, string>? Properties { get; set; }

    /// <summary>The inventory rows. One element becomes one row in the custom table.</summary>
    [JsonPropertyName("records")]
    public List<JsonElement>? Records { get; set; }

    /// <summary>Result of <see cref="Validate"/>.</summary>
    public sealed record ValidationResult(bool Ok, string? Reason)
    {
        public static readonly ValidationResult Success = new(true, null);
        public static ValidationResult Fail(string reason) => new(false, reason);
    }

    /// <summary>
    /// Structural validation only. Trust decisions live in the security pipeline.
    /// </summary>
    public ValidationResult Validate(int maxRecords)
    {
        if (!string.Equals(EnvelopeVersion?.Trim(), CurrentVersion, StringComparison.Ordinal))
            return ValidationResult.Fail($"unsupported envelopeVersion '{EnvelopeVersion}'");

        if (string.IsNullOrWhiteSpace(TableName))
            return ValidationResult.Fail("tableName is required");

        if (!IsSafeTableName(TableName!))
            return ValidationResult.Fail("tableName contains unsupported characters");

        if (string.IsNullOrWhiteSpace(EntraDeviceId) || !Guid.TryParse(EntraDeviceId, out _))
            return ValidationResult.Fail("entraDeviceId must be a GUID");

        if (Records is null || Records.Count == 0)
            return ValidationResult.Fail("records must contain at least one entry");

        if (Records.Count > maxRecords)
            return ValidationResult.Fail($"records exceeds the maximum of {maxRecords} entries");

        foreach (var record in Records)
        {
            if (record.ValueKind != JsonValueKind.Object)
                return ValidationResult.Fail("every records entry must be a JSON object");
        }

        if (Properties is not null && Properties.Count > 32)
            return ValidationResult.Fail("properties exceeds the maximum of 32 entries");

        if (CollectedAtUtc is null)
            return ValidationResult.Fail("collectedAtUtc is required");

        return ValidationResult.Success;
    }

    /// <summary>
    /// Table names flow into a stream-name lookup and into blob paths, so they are
    /// restricted to the Log Analytics custom-table grammar and length limit.
    /// </summary>
    public static bool IsSafeTableName(string tableName)
    {
        if (tableName.Length is 0 or > 100) return false;
        if (!char.IsAsciiLetter(tableName[0])) return false;
        foreach (var c in tableName)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '_') return false;
        }
        return true;
    }
}
