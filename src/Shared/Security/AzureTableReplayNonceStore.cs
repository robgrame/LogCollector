using System.Security.Cryptography;
using System.Text;
using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

namespace LogCollector.Shared.Security;

/// <summary>
/// Azure Table implementation of the distributed replay nonce store. The
/// insert-only <c>AddEntity</c> call is the atomic primitive: a 409 means
/// another instance (or an earlier replay of the same request) already claimed
/// the nonce.
/// </summary>
public sealed class AzureTableReplayNonceStore : IReplayNonceStore
{
    private readonly TableClient _table;
    private readonly ILogger<AzureTableReplayNonceStore> _log;
    private readonly SemaphoreSlim _ensureLock = new(1, 1);
    private volatile bool _tableEnsured;

    public AzureTableReplayNonceStore(TableClient table, ILogger<AzureTableReplayNonceStore> log)
    {
        _table = table;
        _log = log;
    }

    public async Task<bool> TryReserveAsync(
        string certificateThumbprint,
        DateTimeOffset requestTimestamp,
        Guid nonce,
        DateTimeOffset expiresAt,
        CancellationToken ct)
    {
        await EnsureTableAsync(ct).ConfigureAwait(false);

        // The partition is derived from the *signed* timestamp so that every replay
        // of the same request lands on the same entity, including across an UTC hour
        // boundary. The row key hashes the thumbprint so the raw certificate
        // identity is never stored, while remaining certificate-scoped.
        var normalizedThumbprint = NormalizeThumbprint(certificateThumbprint);
        var rowMaterial = Encoding.UTF8.GetBytes($"{normalizedThumbprint}:{nonce:N}");
        var rowKey = Convert.ToHexString(SHA256.HashData(rowMaterial)).ToLowerInvariant();
        var partitionKey = $"{requestTimestamp.UtcDateTime:yyyyMMddHH}-{rowKey[0]}";

        var entity = new TableEntity(partitionKey, rowKey)
        {
            ["RequestTimestamp"] = requestTimestamp,
            ["ExpiresAt"] = expiresAt,
            ["CertificateThumbprintHash"] = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(normalizedThumbprint))).ToLowerInvariant(),
        };

        return await AddEntityAsync(entity, retryAfterMissingTable: true, ct).ConfigureAwait(false);
    }

    public async Task<int> PurgeExpiredAsync(DateTimeOffset cutoff, int maxEntities, CancellationToken ct)
    {
        await EnsureTableAsync(ct).ConfigureAwait(false);

        var deleted = 0;
        var cutoffPartition = $"{cutoff.UtcDateTime:yyyyMMddHH}-";
        var filter = TableClient.CreateQueryFilter($"PartitionKey lt {cutoffPartition}");

        await foreach (var entity in _table.QueryAsync<TableEntity>(
            filter: filter,
            maxPerPage: Math.Min(Math.Max(1, maxEntities), 1000),
            cancellationToken: ct))
        {
            try
            {
                await _table.DeleteEntityAsync(entity.PartitionKey, entity.RowKey, ETag.All, ct).ConfigureAwait(false);
                deleted++;
            }
            catch (RequestFailedException ex) when (ex.Status == 404)
            {
                // Another cleanup invocation already removed it.
            }

            if (deleted >= maxEntities) break;
        }

        return deleted;
    }

    private async Task<bool> AddEntityAsync(TableEntity entity, bool retryAfterMissingTable, CancellationToken ct)
    {
        try
        {
            await _table.AddEntityAsync(entity, ct).ConfigureAwait(false);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == 409)
        {
            _log.LogWarning(
                "Replay nonce collision: partition={Partition} row={Row}",
                entity.PartitionKey, entity.RowKey);
            return false;
        }
        catch (RequestFailedException ex) when (ex.Status == 404 && retryAfterMissingTable)
        {
            _tableEnsured = false;
            await EnsureTableAsync(ct).ConfigureAwait(false);
            return await AddEntityAsync(entity, retryAfterMissingTable: false, ct).ConfigureAwait(false);
        }
    }

    private async Task EnsureTableAsync(CancellationToken ct)
    {
        if (_tableEnsured) return;

        await _ensureLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_tableEnsured) return;
            await _table.CreateIfNotExistsAsync(ct).ConfigureAwait(false);
            _tableEnsured = true;
        }
        finally
        {
            _ensureLock.Release();
        }
    }

    private static string NormalizeThumbprint(string value)
        => new(value.Where(c => !char.IsWhiteSpace(c) && c != ':').ToArray());
}
