using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Configuration;

namespace LogCollector.Frontend.Services;

public sealed class UserSessionOptions
{
    public const string RegistrationHeaderName =
        "X-LogCollector-User-Session";

    private const string CorrelationDomain =
        "EndpointDataSprawlRemediator.User.v2\0";
    private readonly byte[] _hmacKey;

    public UserSessionOptions(IConfiguration configuration)
    {
        var tenantValue = configuration["UserSession:TenantId"];
        Audience = configuration["UserSession:Audience"]?.Trim() ?? string.Empty;
        RequiredScope =
            configuration["UserSession:RequiredScope"]?.Trim() ?? string.Empty;
        MetadataAddress =
            configuration["UserSession:MetadataAddress"]?.Trim() ?? string.Empty;
        TableName =
            configuration["UserSession:TableName"]?.Trim() ?? "UserSessions";
        var keyValue = configuration["UserSession:HmacKeyBase64"];

        var ttlValue = configuration["UserSession:RegistrationTtlMinutes"];
        RegistrationTtl = TimeSpan.FromMinutes(
            string.IsNullOrWhiteSpace(ttlValue)
                ? 480
                : int.TryParse(ttlValue, out var ttlMinutes)
                    ? ttlMinutes
                    : throw new InvalidOperationException(
                        "UserSession:RegistrationTtlMinutes must be an integer."));

        if (RegistrationTtl < TimeSpan.FromMinutes(1) ||
            RegistrationTtl > TimeSpan.FromHours(24))
        {
            throw new InvalidOperationException(
                "UserSession:RegistrationTtlMinutes must be between 1 and 1440.");
        }

        if (!Regex.IsMatch(
            TableName,
            "^[A-Za-z][A-Za-z0-9]{2,62}$",
            RegexOptions.CultureInvariant))
        {
            throw new InvalidOperationException(
                "UserSession:TableName must be a valid Azure Table name.");
        }

        IsConfigured =
            !string.IsNullOrWhiteSpace(tenantValue) &&
            !string.IsNullOrWhiteSpace(Audience) &&
            !string.IsNullOrWhiteSpace(RequiredScope) &&
            !string.IsNullOrWhiteSpace(MetadataAddress) &&
            !string.IsNullOrWhiteSpace(keyValue);
        if (!IsConfigured)
        {
            TenantId = Guid.Empty;
            Issuer = string.Empty;
            _hmacKey = [];
            return;
        }

        if (!Guid.TryParse(tenantValue, out var tenantId))
        {
            throw new InvalidOperationException(
                "UserSession:TenantId must be a GUID.");
        }

        if (!Uri.TryCreate(MetadataAddress, UriKind.Absolute, out var metadataUri) ||
            metadataUri.Scheme != Uri.UriSchemeHttps)
        {
            throw new InvalidOperationException(
                "UserSession:MetadataAddress must be an absolute HTTPS URI.");
        }

        try
        {
            _hmacKey = Convert.FromBase64String(keyValue!);
        }
        catch (FormatException exception)
        {
            throw new InvalidOperationException(
                "UserSession:HmacKeyBase64 must be valid Base64.",
                exception);
        }

        if (_hmacKey.Length < 32)
        {
            throw new InvalidOperationException(
                "UserSession:HmacKeyBase64 must decode to at least 32 bytes.");
        }

        TenantId = tenantId;
        Issuer =
            $"{metadataUri.Scheme}://{metadataUri.Authority}/{tenantId:D}/v2.0";
    }

    public bool IsConfigured { get; }

    public Guid TenantId { get; }

    public string Issuer { get; }

    public string Audience { get; }

    public string RequiredScope { get; }

    public string MetadataAddress { get; }

    public string TableName { get; }

    public TimeSpan RegistrationTtl { get; }

    public string ComputeCorrelation(Guid userObjectId)
    {
        if (!IsConfigured)
        {
            throw new InvalidOperationException(
                "Endpoint Data Sprawl user sessions are not configured.");
        }

        var input = Encoding.UTF8.GetBytes(
            CorrelationDomain +
            TenantId.ToString("D").ToUpperInvariant() +
            "\0" +
            userObjectId.ToString("D").ToUpperInvariant());
        return Convert.ToHexString(HMACSHA256.HashData(_hmacKey, input));
    }
}
