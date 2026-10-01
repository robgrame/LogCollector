using System.Security.Cryptography;
using System.Text;
using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

namespace LogCollector.Frontend.Services;

public sealed record CreatedUserSession(
    string RegistrationId,
    DateTimeOffset ExpiresAtUtc);

public sealed record ResolvedUserSession(
    bool Resolved,
    string? UserCorrelationId,
    string? FailureReason)
{
    public static ResolvedUserSession Success(string correlationId) =>
        new(true, correlationId, null);

    public static ResolvedUserSession Failure(string reason) =>
        new(false, null, reason);
}

public interface IUserSessionStore
{
    Task<CreatedUserSession> CreateAsync(
        Guid trustedDeviceId,
        string userCorrelationId,
        DateTimeOffset tokenExpiresAtUtc,
        CancellationToken cancellationToken);

    Task<ResolvedUserSession> ResolveAsync(
        string registrationId,
        Guid trustedDeviceId,
        CancellationToken cancellationToken);

    Task<bool> RevokeAsync(
        string registrationId,
        Guid trustedDeviceId,
        CancellationToken cancellationToken);

    Task<int> PurgeExpiredAsync(
        DateTimeOffset cutoff,
        int maxEntities,
        CancellationToken cancellationToken);
}

public sealed class AzureTableUserSessionStore(
    TableClient table,
    UserSessionOptions options,
    TimeProvider timeProvider,
    ILogger<AzureTableUserSessionStore> logger) : IUserSessionStore
{
    private readonly SemaphoreSlim _ensureLock = new(1, 1);
    private volatile bool _tableEnsured;

    public async Task<CreatedUserSession> CreateAsync(
        Guid trustedDeviceId,
        string userCorrelationId,
        DateTimeOffset tokenExpiresAtUtc,
        CancellationToken cancellationToken)
    {
        await EnsureTableAsync(cancellationToken).ConfigureAwait(false);

        var now = timeProvider.GetUtcNow();
        var expiresAt = new[]
        {
            now.Add(options.RegistrationTtl),
            tokenExpiresAtUtc,
        }.Min();
        if (expiresAt <= now)
        {
            throw new InvalidOperationException(
                "Delegated access token has no remaining registration lifetime.");
        }

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var registrationId = CreateOpaqueRegistrationId();
            var hash = HashRegistrationId(registrationId);
            var entity = new TableEntity(PartitionKey(hash), hash)
            {
                ["TrustedDeviceId"] = trustedDeviceId.ToString("D"),
                ["UserCorrelationId"] = userCorrelationId,
                ["CreatedAtUtc"] = now,
                ["ExpiresAtUtc"] = expiresAt,
                ["RevokedAtUtc"] = null,
            };

            try
            {
                await table
                    .AddEntityAsync(entity, cancellationToken)
                    .ConfigureAwait(false);
                return new CreatedUserSession(registrationId, expiresAt);
            }
            catch (RequestFailedException exception) when (exception.Status == 409)
            {
                logger.LogWarning(
                    "User-session registration hash collision; generating a replacement.");
            }
        }

        throw new CryptographicException(
            "Unable to allocate a unique user-session registration.");
    }

    public async Task<ResolvedUserSession> ResolveAsync(
        string registrationId,
        Guid trustedDeviceId,
        CancellationToken cancellationToken)
    {
        var entity = await GetAsync(registrationId, cancellationToken)
            .ConfigureAwait(false);
        if (entity is null)
        {
            return ResolvedUserSession.Failure(
                "User-session registration is invalid.");
        }

        var now = timeProvider.GetUtcNow();
        if (entity.GetDateTimeOffset("RevokedAtUtc").HasValue)
        {
            return ResolvedUserSession.Failure(
                "User-session registration has been revoked.");
        }

        var expiresAt = entity.GetDateTimeOffset("ExpiresAtUtc");
        if (!expiresAt.HasValue || expiresAt.Value <= now)
        {
            return ResolvedUserSession.Failure(
                "User-session registration has expired.");
        }

        if (!Guid.TryParse(
                entity.GetString("TrustedDeviceId"),
                out var storedDeviceId) ||
            storedDeviceId != trustedDeviceId)
        {
            return ResolvedUserSession.Failure(
                "User-session registration is bound to another device.");
        }

        var correlationId = entity.GetString("UserCorrelationId");
        if (correlationId is null ||
            correlationId.Length != 64 ||
            !correlationId.All(Uri.IsHexDigit))
        {
            return ResolvedUserSession.Failure(
                "User-session registration metadata is invalid.");
        }

        return ResolvedUserSession.Success(correlationId.ToUpperInvariant());
    }

    public async Task<bool> RevokeAsync(
        string registrationId,
        Guid trustedDeviceId,
        CancellationToken cancellationToken)
    {
        var entity = await GetAsync(registrationId, cancellationToken)
            .ConfigureAwait(false);
        if (entity is null ||
            !Guid.TryParse(entity.GetString("TrustedDeviceId"), out var storedDeviceId) ||
            storedDeviceId != trustedDeviceId)
        {
            return false;
        }

        entity["RevokedAtUtc"] = timeProvider.GetUtcNow();
        entity["UserCorrelationId"] = null;
        await table
            .UpdateEntityAsync(
                entity,
                entity.ETag,
                TableUpdateMode.Replace,
                cancellationToken)
            .ConfigureAwait(false);
        return true;
    }

    public async Task<int> PurgeExpiredAsync(
        DateTimeOffset cutoff,
        int maxEntities,
        CancellationToken cancellationToken)
    {
        await EnsureTableAsync(cancellationToken).ConfigureAwait(false);
        var removed = 0;
        var filter =
            TableClient.CreateQueryFilter($"ExpiresAtUtc le {cutoff}");
        await foreach (var entity in table.QueryAsync<TableEntity>(
            filter: filter,
            maxPerPage: Math.Min(Math.Max(1, maxEntities), 1000),
            cancellationToken: cancellationToken))
        {
            try
            {
                await table.DeleteEntityAsync(
                    entity.PartitionKey,
                    entity.RowKey,
                    entity.ETag,
                    cancellationToken)
                    .ConfigureAwait(false);
                removed++;
            }
            catch (RequestFailedException exception)
                when (exception.Status == 404)
            {
            }

            if (removed >= maxEntities)
            {
                break;
            }
        }

        return removed;
    }

    private async Task<TableEntity?> GetAsync(
        string registrationId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(registrationId) ||
            registrationId.Length > 256)
        {
            return null;
        }

        await EnsureTableAsync(cancellationToken).ConfigureAwait(false);
        var hash = HashRegistrationId(registrationId);
        try
        {
            var response = await table
                .GetEntityAsync<TableEntity>(
                    PartitionKey(hash),
                    hash,
                    cancellationToken: cancellationToken)
                .ConfigureAwait(false);
            return response.Value;
        }
        catch (RequestFailedException exception) when (exception.Status == 404)
        {
            return null;
        }
    }

    private async Task EnsureTableAsync(CancellationToken cancellationToken)
    {
        if (_tableEnsured)
        {
            return;
        }

        await _ensureLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_tableEnsured)
            {
                return;
            }

            await table
                .CreateIfNotExistsAsync(cancellationToken)
                .ConfigureAwait(false);
            _tableEnsured = true;
        }
        finally
        {
            _ensureLock.Release();
        }
    }

    private static string CreateOpaqueRegistrationId()
    {
        var value = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        return value.TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static string HashRegistrationId(string registrationId) =>
        Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(registrationId)))
            .ToLowerInvariant();

    private static string PartitionKey(string hash) => $"session-{hash[..2]}";
}
