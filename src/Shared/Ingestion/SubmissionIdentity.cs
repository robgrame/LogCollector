using System.Security.Cryptography;
using System.Text;

namespace LogCollector.Shared.Ingestion;

public static class SubmissionIdentity
{
    public static string FromBody(ReadOnlySpan<byte> authenticatedBody)
        => Convert.ToHexString(SHA256.HashData(authenticatedBody)).ToLowerInvariant();

    public static string FromBodyAndUserContext(
        ReadOnlySpan<byte> authenticatedBody,
        string? userCorrelationId)
    {
        if (userCorrelationId is null)
        {
            return FromBody(authenticatedBody);
        }

        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(authenticatedBody);
        hash.AppendData([0]);
        hash.AppendData(
            Encoding.ASCII.GetBytes(userCorrelationId.ToUpperInvariant()));
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
}
