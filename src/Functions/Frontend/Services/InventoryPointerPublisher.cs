using System.Security.Cryptography;
using System.Text.Json;
using Azure;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using LogCollector.Shared.Models;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Services;

/// <summary>
/// Persists the accepted payload to Blob storage and publishes a pointer message
/// on Service Bus.
/// </summary>
/// <remarks>
/// Order matters and is not interchangeable: the blob is written <b>before</b>
/// the pointer is enqueued. A crash between the two leaves an orphan blob that
/// lifecycle management reclaims, whereas the reverse order would produce a
/// pointer to a blob that never existed and a message that dead-letters after
/// exhausting every delivery attempt.
/// </remarks>
public sealed class InventoryPointerPublisher
{
    private static readonly JsonSerializerOptions PointerJson = new(JsonSerializerDefaults.Web);

    private readonly BlobContainerClient _container;
    private readonly ServiceBusClient _serviceBus;
    private readonly InventoryIntakeOptions _options;
    private readonly ILogger<InventoryPointerPublisher> _log;
    private readonly SemaphoreSlim _containerLock = new(1, 1);
    private volatile bool _containerEnsured;

    public InventoryPointerPublisher(
        BlobContainerClient container,
        ServiceBusClient serviceBus,
        InventoryIntakeOptions options,
        ILogger<InventoryPointerPublisher> log)
    {
        _container = container;
        _serviceBus = serviceBus;
        _options = options;
        _log = log;
    }

    public async Task<QueuedIngestionMessage> PublishAsync(
        InventoryEnvelope envelope,
        byte[] bodyBytes,
        string correlationId,
        string? certificateThumbprint,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        ArgumentNullException.ThrowIfNull(bodyBytes);

        await EnsureContainerAsync(ct).ConfigureAwait(false);

        var now = DateTimeOffset.UtcNow;

        // Content-derived IDs make retries target the same immutable blob.
        var blobName = $"{envelope.TableName}/{correlationId}.json";
        var blobClient = _container.GetBlobClient(blobName);

        var sha256 = Convert.ToBase64String(SHA256.HashData(bodyBytes));

        try
        {
            await blobClient.UploadAsync(
            BinaryData.FromBytes(bodyBytes),
            new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" },
                Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
                Metadata = new Dictionary<string, string>
                {
                    ["correlationId"] = correlationId,
                    ["entraDeviceId"] = envelope.EntraDeviceId ?? string.Empty,
                    ["tableName"] = envelope.TableName ?? string.Empty,
                },
            },
                ct).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (
            (ex.Status == 409 && ex.ErrorCode == "BlobAlreadyExists")
            || (ex.Status == 412 && ex.ErrorCode == "ConditionNotMet"))
        {
            _log.LogInformation("Submission blob already exists for {CorrelationId}; retrying pointer publication.", correlationId);
        }

        var pointer = new QueuedIngestionMessage
        {
            CorrelationId = correlationId,
            TableName = envelope.TableName!,
            ContainerName = _options.ContainerName,
            BlobName = blobName,
            PayloadSha256 = sha256,
            PayloadBytes = bodyBytes.LongLength,
            EntraDeviceId = envelope.EntraDeviceId!,
            DeviceName = envelope.DeviceName,
            Source = envelope.Source,
            CollectedAtUtc = envelope.CollectedAtUtc ?? now,
            AcceptedAtUtc = now,
            CertificateThumbprint = certificateThumbprint,
        };

        await using var sender = _serviceBus.CreateSender(_options.QueueName);
        var message = new ServiceBusMessage(BinaryData.FromString(JsonSerializer.Serialize(pointer, PointerJson)))
        {
            ContentType = "application/json",
            CorrelationId = correlationId,
            Subject = envelope.TableName,
            // Duplicate detection is enabled on the queue; a stable id makes a
            // client-side retry of an already-accepted submission a no-op.
            MessageId = correlationId,
        };

        await sender.SendMessageAsync(message, ct).ConfigureAwait(false);

        _log.LogInformation(
            "Accepted inventory submission: correlationId={CorrelationId} table={Table} bytes={Bytes} blob={Blob}",
            correlationId, envelope.TableName, bodyBytes.LongLength, blobName);

        return pointer;
    }

    private async Task EnsureContainerAsync(CancellationToken ct)
    {
        if (_containerEnsured) return;

        await _containerLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_containerEnsured) return;
            await _container.CreateIfNotExistsAsync(PublicAccessType.None, cancellationToken: ct).ConfigureAwait(false);
            _containerEnsured = true;
        }
        finally
        {
            _containerLock.Release();
        }
    }
}
