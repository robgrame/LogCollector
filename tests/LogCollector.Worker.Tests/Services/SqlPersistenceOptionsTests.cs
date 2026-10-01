using LogCollector.Worker.Services;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace LogCollector.Worker.Tests.Services;

public sealed class SqlPersistenceOptionsTests
{
    [Fact]
    public void Constructor_DefaultsToDisabledEndpointDataSprawlPersistence()
    {
        var configuration = new ConfigurationBuilder().Build();

        var options = new SqlPersistenceOptions(configuration);

        Assert.False(options.Enabled);
        Assert.Equal(
            SqlPersistenceOptions.DefaultTargetTable,
            options.TargetTableName);
        Assert.Equal(2_555, options.RetentionDays);
        Assert.Equal(3_650, options.PlacementRetentionDays);
    }

    [Theory]
    [InlineData("3651", 3651)]
    [InlineData("99999", 36500)]
    public void Constructor_ClampsPlacementRetentionDays(
        string configured,
        int expected)
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:PlacementRetentionDays"] = configured,
        });

        var options = new SqlPersistenceOptions(configuration);

        Assert.Equal(expected, options.PlacementRetentionDays);
    }

    [Fact]
    public void Constructor_RequiresPlacementRetentionLongerThanEventRetention()
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:RetentionDays"] = "365",
            ["SqlPersistence:PlacementRetentionDays"] = "365",
        });

        var exception = Assert.Throws<InvalidOperationException>(
            () => new SqlPersistenceOptions(configuration));

        Assert.Contains(
            "PlacementRetentionDays",
            exception.Message,
            StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("1", 30)]
    [InlineData("365", 365)]
    [InlineData("9999", 3650)]
    public void Constructor_ClampsRetentionDays(string configured, int expected)
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:RetentionDays"] = configured,
        });

        var options = new SqlPersistenceOptions(configuration);

        Assert.Equal(expected, options.RetentionDays);
    }

    [Fact]
    public void Constructor_RequiresConnectionStringWhenEnabled()
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:Enabled"] = "true",
        });

        var exception = Assert.Throws<InvalidOperationException>(
            () => new SqlPersistenceOptions(configuration));

        Assert.Contains("ConnectionString", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Constructor_AcceptsManagedIdentityConnectionString()
    {
        const string connectionString =
            "Server=tcp:logcollector-sql.database.windows.net,1433;" +
            "Database=EndpointDataSprawl;" +
            "Authentication=Active Directory Managed Identity;" +
            "User Id=11111111-1111-1111-1111-111111111111;" +
            "Encrypt=True;TrustServerCertificate=False;";
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:Enabled"] = "true",
            ["SqlPersistence:ConnectionString"] = connectionString,
        });

        var options = new SqlPersistenceOptions(configuration);

        Assert.True(options.Enabled);
        Assert.Equal(connectionString, options.ConnectionString);
    }

    [Theory]
    [InlineData("unsafe table")]
    [InlineData("EndpointDataSprawlRemediator_CL;DROP TABLE")]
    public void Constructor_RejectsUnsafeTargetTableName(string tableName)
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:TargetTableName"] = tableName,
        });

        Assert.Throws<InvalidOperationException>(
            () => new SqlPersistenceOptions(configuration));
    }

    [Fact]
    public void Constructor_RejectsAnEnabledNonEndpointTarget()
    {
        var configuration = BuildConfiguration(new Dictionary<string, string?>
        {
            ["SqlPersistence:Enabled"] = "true",
            ["SqlPersistence:ConnectionString"] = "Server=tcp:test.database.windows.net;Database=test;",
            ["SqlPersistence:TargetTableName"] = "OtherTelemetry_CL",
        });

        var exception = Assert.Throws<InvalidOperationException>(
            () => new SqlPersistenceOptions(configuration));

        Assert.Contains(
            SqlPersistenceOptions.DefaultTargetTable,
            exception.Message,
            StringComparison.Ordinal);
    }

    private static IConfiguration BuildConfiguration(
        IDictionary<string, string?> values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();
}
