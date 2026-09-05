using System.Security.Cryptography;

namespace LogCollector.Shared.Ingestion;

public static class SubmissionIdentity
{
    public static string FromBody(ReadOnlySpan<byte> authenticatedBody)
        => Convert.ToHexString(SHA256.HashData(authenticatedBody)).ToLowerInvariant();
}
