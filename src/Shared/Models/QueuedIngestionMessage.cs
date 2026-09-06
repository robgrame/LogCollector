using System.Text.Json.Serialization;

namespace LogCollector.Shared.Models;

/// <summary>
/// Service Bus <i>pointer</i> message. The payload itself never travels on the
/// queue — only the blob coordinates do, which keeps messages far below the
/// Service Bus Standard 256 KB limit regardless of payload size.
/// </summary>
/// <remarks>
/// The pointer intentionally carries the container and blob <b>name</b> rather
/// than an absolute URI. The worker resolves it against its own configured
/// storage account, so a forged or tampered message can never make the worker
/// fetch from an attacker-controlled host (SSRF).
/// </remarks>
public sealed class QueuedIngestionMessage
{
    public const string CurrentVersion = "LOGCOLLECTOR-POINTER-V1";

    [JsonPropertyName("version")]
    public string Version { get; set; } = CurrentVersion;

    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; set; } = string.Empty;

    [JsonPropertyName("tableName")]
    public string TableName { get; set; } = string.Empty;

    [JsonPropertyName("containerName")]
    public string ContainerName { get; set; } = string.Empty;

    [JsonPropertyName("blobName")]
    public string BlobName { get; set; } = string.Empty;

    /// <summary>SHA-256 (Base64) of the exact bytes persisted to the blob.</summary>
    [JsonPropertyName("payloadSha256")]
    public string PayloadSha256 { get; set; } = string.Empty;

    [JsonPropertyName("payloadBytes")]
    public long PayloadBytes { get; set; }

    [JsonPropertyName("entraDeviceId")]
    public string EntraDeviceId { get; set; } = string.Empty;

    [JsonPropertyName("deviceName")]
    public string? DeviceName { get; set; }

    [JsonPropertyName("source")]
    public string? Source { get; set; }

    [JsonPropertyName("collectedAtUtc")]
    public DateTimeOffset CollectedAtUtc { get; set; }

    [JsonPropertyName("acceptedAtUtc")]
    public DateTimeOffset AcceptedAtUtc { get; set; }

    /// <summary>Thumbprint of the validated client certificate, for audit joins.</summary>
    [JsonPropertyName("certificateThumbprint")]
    public string? CertificateThumbprint { get; set; }

    public sealed record ValidationResult(bool Ok, string? Reason);

    public ValidationResult Validate()
    {
        if (!string.Equals(Version?.Trim(), CurrentVersion, StringComparison.Ordinal))
            return new ValidationResult(false, $"unsupported pointer version '{Version}'");
        if (string.IsNullOrWhiteSpace(ContainerName))
            return new ValidationResult(false, "containerName is required");
        if (string.IsNullOrWhiteSpace(BlobName))
            return new ValidationResult(false, "blobName is required");
        if (BlobName.Contains("..", StringComparison.Ordinal) || BlobName.StartsWith('/'))
            return new ValidationResult(false, "blobName is not a canonical relative blob path");
        if (string.IsNullOrWhiteSpace(TableName) || !TelemetryEnvelope.IsSafeTableName(TableName))
            return new ValidationResult(false, "tableName is missing or invalid");
        if (string.IsNullOrWhiteSpace(CorrelationId))
            return new ValidationResult(false, "correlationId is required");
        if (!Guid.TryParse(EntraDeviceId, out _))
            return new ValidationResult(false, "entraDeviceId must be a GUID");
        if (PayloadBytes <= 0)
            return new ValidationResult(false, "payloadBytes must be positive");
        Span<byte> digest = stackalloc byte[32];
        if (string.IsNullOrWhiteSpace(PayloadSha256)
            || !Convert.TryFromBase64String(PayloadSha256, digest, out var digestLength)
            || digestLength != 32)
            return new ValidationResult(false, "payloadSha256 must be a base64 SHA-256 digest");
        return new ValidationResult(true, null);
    }
}
