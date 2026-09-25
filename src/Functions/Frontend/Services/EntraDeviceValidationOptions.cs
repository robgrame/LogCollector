using Microsoft.Extensions.Configuration;

namespace LogCollector.Frontend.Services;

/// <summary>Controls the optional tenant-device lookup for Intune enrollment certificates.</summary>
public sealed class EntraDeviceValidationOptions
{
    public EntraDeviceValidationOptions(IConfiguration cfg)
    {
        var configured = cfg["EntraDeviceValidation:Enabled"];
        if (string.IsNullOrWhiteSpace(configured))
        {
            Enabled = true;
            return;
        }

        if (!bool.TryParse(configured, out var enabled))
            throw new InvalidOperationException(
                "Setting 'EntraDeviceValidation:Enabled' must be 'true' or 'false'.");

        Enabled = enabled;
    }

    public bool Enabled { get; }
}
