using System.Text.RegularExpressions;

namespace LogCollector.DatabaseInitializer;

public sealed record DatabaseInitializationOptions(
    string Server,
    string Database,
    string WorkerIdentityName,
    Guid WorkerIdentityClientId,
    string SchemaPath,
    string? DashboardIdentityName,
    Guid? DashboardIdentityClientId);

public static class DatabaseInitializationOptionsParser
{
    public static DatabaseInitializationOptions Parse(string[] values)
    {
        var arguments = ParsePairs(values);
        var server = Required(arguments, "server");
        var database = Required(arguments, "database");
        var workerIdentityName = Required(arguments, "worker-identity-name");
        var workerIdentityClientId = ParseGuid(arguments, "worker-identity-client-id");
        var dashboardIdentityName = Optional(arguments, "dashboard-identity-name");
        var dashboardIdentityClientIdValue = Optional(arguments, "dashboard-identity-client-id");
        var schemaPath = Required(arguments, "schema");

        if (!Regex.IsMatch(server, "^[a-z0-9-]{1,63}$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(database, "^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(
                workerIdentityName,
                "^[A-Za-z0-9-]{2,128}$",
                RegexOptions.CultureInvariant) ||
            (dashboardIdentityName is not null &&
             !Regex.IsMatch(
                 dashboardIdentityName,
                 "^[A-Za-z0-9-]{2,128}$",
                 RegexOptions.CultureInvariant)))
        {
            throw new ArgumentException("One or more database initializer identifiers are invalid.");
        }

        if ((dashboardIdentityName is null) != (dashboardIdentityClientIdValue is null))
        {
            throw new ArgumentException(
                "Dashboard identity name and client id must either both be supplied or both be omitted.");
        }

        var dashboardIdentityClientId = dashboardIdentityClientIdValue is null
            ? (Guid?)null
            : ParseGuid(arguments, "dashboard-identity-client-id");

        return new DatabaseInitializationOptions(
            server,
            database,
            workerIdentityName,
            workerIdentityClientId,
            schemaPath,
            dashboardIdentityName,
            dashboardIdentityClientId);
    }

    public static string RenderSchema(string sql, DatabaseInitializationOptions options)
    {
        var escapedWorkerIdentityName =
            options.WorkerIdentityName.Replace("]", "]]", StringComparison.Ordinal);
        var escapedDashboardIdentityName = (options.DashboardIdentityName ??
            "endpoint-data-sprawl-dashboard-not-configured")
            .Replace("]", "]]", StringComparison.Ordinal);

        return sql
            .Replace(
                "__WORKER_IDENTITY_NAME__",
                escapedWorkerIdentityName,
                StringComparison.Ordinal)
            .Replace(
                "__WORKER_IDENTITY_SID_HEX__",
                Convert.ToHexString(options.WorkerIdentityClientId.ToByteArray()),
                StringComparison.Ordinal)
            .Replace(
                "__DASHBOARD_IDENTITY_ENABLED__",
                options.DashboardIdentityClientId.HasValue ? "1" : "0",
                StringComparison.Ordinal)
            .Replace(
                "__DASHBOARD_IDENTITY_NAME__",
                escapedDashboardIdentityName,
                StringComparison.Ordinal)
            .Replace(
                "__DASHBOARD_IDENTITY_SID_HEX__",
                Convert.ToHexString(
                    (options.DashboardIdentityClientId ?? Guid.Empty).ToByteArray()),
                StringComparison.Ordinal);
    }

    private static Dictionary<string, string> ParsePairs(string[] values)
    {
        var parsed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < values.Length; index += 2)
        {
            if (index + 1 >= values.Length ||
                !values[index].StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException("Arguments must use --name value pairs.");
            }

            parsed[values[index][2..]] = values[index + 1];
        }

        return parsed;
    }

    private static string Required(IReadOnlyDictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required argument --{name}.");

    private static string? Optional(IReadOnlyDictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : null;

    private static Guid ParseGuid(IReadOnlyDictionary<string, string> values, string name) =>
        Guid.TryParse(Required(values, name), out var value)
            ? value
            : throw new ArgumentException($"Argument --{name} must be a valid GUID.");
}
