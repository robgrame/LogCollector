using System.Security.Cryptography;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using LogCollector.Shared.Models;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Services;

/// <summary>
/// Reads the payload blob referenced by a pointer message.
/// </summary>
/// <remarks>
/// The pointer is untrusted input on the wire, so the blob is resolved against
/// the worker's <b>own</b> configured account and container allow-list rather
/// than any URI carried in the message. That removes the SSRF class entirely:
/// there is no code path where message content selects the host to fetch from.
/// The SHA-256 recorded at intake is re-verified so a tampered or truncated blob
/// never reaches ingestion.
/// </remarks>
public sealed class PayloadBlobReader
{
    private readonly BlobServiceClient _blobService;
    private readonly WorkerIngestionOptions _options;
    private readonly ILogger<PayloadBlobReader> _log;

    public PayloadBlobReader(BlobServiceClient blobService, WorkerIngestionOptions options, ILogger<PayloadBlobReader> log)
    {
        _blobService = blobService;
        _options = options;
        _log = log;
    }

    public sealed record PayloadReadResult(bool Ok, string? Reason, byte[] Content, ETag ETag, bool Permanent);

    public async Task<PayloadReadResult> ReadAsync(QueuedIngestionMessage pointer, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(pointer);

        if (!string.Equals(pointer.ContainerName, _options.PayloadContainer, StringComparison.Ordinal))
        {
            return Permanent($"pointer container '{pointer.ContainerName}' is not the configured payload container");
        }

        var blobClient = _blobService
            .GetBlobContainerClient(_options.PayloadContainer)
            .GetBlobClient(pointer.BlobName);

        BlobDownloadResult download;
        try
        {
            download = await blobClient.DownloadContentAsync(ct).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            // Already reclaimed by retention, or already processed and deleted.
            // Either way retrying will never succeed.
            return Permanent($"payload blob '{pointer.BlobName}' does not exist");
        }

        var content = download.Content.ToArray();

        if (content.LongLength != pointer.PayloadBytes)
            return Permanent("payload byte length does not match the value recorded at intake");

        if (string.IsNullOrWhiteSpace(pointer.PayloadSha256))
            return Permanent("payload digest is required");

        var actual = Convert.ToBase64String(SHA256.HashData(content));
        if (!CryptographicOperations.FixedTimeEquals(
                System.Text.Encoding.ASCII.GetBytes(actual),
                System.Text.Encoding.ASCII.GetBytes(pointer.PayloadSha256)))
        {
            _log.LogError(
                "Payload digest mismatch for correlationId={CorrelationId} blob={Blob}",
                pointer.CorrelationId, pointer.BlobName);
            return Permanent("payload digest does not match the value recorded at intake");
        }

        return new PayloadReadResult(true, null, content, download.Details.ETag, false);
    }

    /// <summary>
    /// Deletes the payload only when it is byte-for-byte the blob that was just
    /// ingested. The ETag precondition means a concurrent overwrite is preserved
    /// instead of silently destroyed.
    /// </summary>
    public async Task<bool> TryDeleteAsync(QueuedIngestionMessage pointer, ETag etag, CancellationToken ct)
    {
        var blobClient = _blobService
            .GetBlobContainerClient(_options.PayloadContainer)
            .GetBlobClient(pointer.BlobName);

        try
        {
            await blobClient.DeleteIfExistsAsync(
                DeleteSnapshotsOption.IncludeSnapshots,
                new BlobRequestConditions { IfMatch = etag },
                ct).ConfigureAwait(false);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status is 412 or 409)
        {
            _log.LogWarning(
                "Skipped payload deletion for {Blob}: the blob changed after ingestion (status {Status}).",
                pointer.BlobName, ex.Status);
            return false;
        }
        catch (RequestFailedException ex)
        {
            // Deletion is best-effort cleanup; lifecycle management is the backstop.
            // Failing the message here would re-ingest already-committed rows.
            _log.LogWarning(ex, "Payload deletion failed for {Blob}; leaving it to lifecycle retention.", pointer.BlobName);
            return false;
        }
    }

    private static PayloadReadResult Permanent(string reason)
        => new(false, reason, [], default, true);
}
