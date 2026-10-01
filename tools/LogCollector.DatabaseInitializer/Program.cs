using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

var arguments = ParseArguments(args);
var server = Required(arguments, "server");
var database = Required(arguments, "database");
var workerIdentityName = Required(arguments, "worker-identity-name");
var workerIdentityClientId = Guid.Parse(Required(arguments, "worker-identity-client-id"));
var schemaPath = Required(arguments, "schema");

if (!Regex.IsMatch(server, "^[a-z0-9-]{1,63}$", RegexOptions.CultureInvariant) ||
    !Regex.IsMatch(database, "^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant) ||
    !Regex.IsMatch(workerIdentityName, "^[A-Za-z0-9-]{2,128}$", RegexOptions.CultureInvariant))
{
    throw new ArgumentException("One or more database initializer identifiers are invalid.");
}

var sql = await File.ReadAllTextAsync(schemaPath, Encoding.UTF8);
var escapedIdentityName = workerIdentityName.Replace("]", "]]", StringComparison.Ordinal);
var sidHex = Convert.ToHexString(workerIdentityClientId.ToByteArray());
sql = sql
    .Replace("__WORKER_IDENTITY_NAME__", escapedIdentityName, StringComparison.Ordinal)
    .Replace("__WORKER_IDENTITY_SID_HEX__", sidHex, StringComparison.Ordinal);

var connectionString = new SqlConnectionStringBuilder
{
    DataSource = $"{server}.database.windows.net,1433",
    InitialCatalog = database,
    Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault,
    Encrypt = true,
    TrustServerCertificate = false,
    ConnectTimeout = 60,
    ConnectRetryCount = 3,
    ConnectRetryInterval = 10,
}.ConnectionString;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

foreach (var batch in Regex.Split(
    sql,
    @"^\s*GO\s*(?:--.*)?$",
    RegexOptions.Multiline | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
{
    if (string.IsNullOrWhiteSpace(batch))
    {
        continue;
    }

    await using var command = new SqlCommand(batch, connection)
    {
        CommandTimeout = 180,
    };
    await command.ExecuteNonQueryAsync();
}

Console.WriteLine($"Applied Endpoint Data Sprawl schema to {server}/{database}.");

static Dictionary<string, string> ParseArguments(string[] values)
{
    var parsed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var index = 0; index < values.Length; index += 2)
    {
        if (index + 1 >= values.Length || !values[index].StartsWith("--", StringComparison.Ordinal))
        {
            throw new ArgumentException("Arguments must use --name value pairs.");
        }

        parsed[values[index][2..]] = values[index + 1];
    }

    return parsed;
}

static string Required(IReadOnlyDictionary<string, string> values, string name) =>
    values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new ArgumentException($"Missing required argument --{name}.");
