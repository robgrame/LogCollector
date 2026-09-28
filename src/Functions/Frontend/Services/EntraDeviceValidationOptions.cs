using Microsoft.Extensions.Configuration;

namespace LogCollector.Frontend.Services;

/// <summary>Controls the optional tenant-device lookup for Intune enrollment certificates.</summary>
public sealed class EntraDeviceValidationOptions
{
    private const int DefaultPositiveCacheMinutes = 240;

    public EntraDeviceValidationOptions(IConfiguration cfg)
    {
        var configured = cfg["EntraDeviceValidation:Enabled"];
        if (string.IsNullOrWhiteSpace(configured))
        {
            Enabled = true;
        }
        else if (!bool.TryParse(configured, out var enabled))
        {
            throw new InvalidOperationException(
                "Setting 'EntraDeviceValidation:Enabled' must be 'true' or 'false'.");
        }
        else
        {
            Enabled = enabled;
        }

        var cacheMinutes = cfg["EntraDeviceValidation:PositiveCacheMinutes"];
        if (string.IsNullOrWhiteSpace(cacheMinutes))
        {
            PositiveCacheDuration = TimeSpan.FromMinutes(DefaultPositiveCacheMinutes);
        }
        else if (!int.TryParse(cacheMinutes, out var minutes) || minutes is < 0 or > 1440)
        {
            throw new InvalidOperationException(
                "Setting 'EntraDeviceValidation:PositiveCacheMinutes' must be an integer from 0 to 1440.");
        }
        else
        {
            PositiveCacheDuration = TimeSpan.FromMinutes(minutes);
        }
    }

    public bool Enabled { get; }
    public TimeSpan PositiveCacheDuration { get; }
}
