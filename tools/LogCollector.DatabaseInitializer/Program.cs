using System.Text;
using System.Text.RegularExpressions;
using LogCollector.DatabaseInitializer;
using Microsoft.Data.SqlClient;

var options = DatabaseInitializationOptionsParser.Parse(args);
var sql = DatabaseInitializationOptionsParser.RenderSchema(
    await File.ReadAllTextAsync(options.SchemaPath, Encoding.UTF8),
    options);

var connectionString = new SqlConnectionStringBuilder
{
    DataSource = $"{options.Server}.database.windows.net,1433",
    InitialCatalog = options.Database,
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

Console.WriteLine(
    $"Applied Endpoint Data Sprawl schema to {options.Server}/{options.Database}.");
