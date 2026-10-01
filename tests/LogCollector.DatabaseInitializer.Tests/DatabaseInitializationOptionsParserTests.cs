using LogCollector.DatabaseInitializer;
using Xunit;

namespace LogCollector.DatabaseInitializer.Tests;

public sealed class DatabaseInitializationOptionsParserTests
{
    [Fact]
    public void Parse_AllowsDashboardIdentityToBeOmitted()
    {
        var options = DatabaseInitializationOptionsParser.Parse(RequiredArguments());

        Assert.Null(options.DashboardIdentityName);
        Assert.Null(options.DashboardIdentityClientId);
    }

    [Fact]
    public void Parse_RejectsPartialDashboardIdentity()
    {
        var arguments = RequiredArguments()
            .Concat(["--dashboard-identity-name", "dashboard"])
            .ToArray();

        var exception = Assert.Throws<ArgumentException>(
            () => DatabaseInitializationOptionsParser.Parse(arguments));

        Assert.Contains("both be supplied or both be omitted", exception.Message);
    }

    [Fact]
    public void RenderSchema_UsesManagedIdentityApplicationIdBytesForSid()
    {
        var dashboardClientId = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");
        var options = DatabaseInitializationOptionsParser.Parse(
            RequiredArguments()
                .Concat(
                [
                    "--dashboard-identity-name",
                    "dashboard",
                    "--dashboard-identity-client-id",
                    dashboardClientId.ToString(),
                ])
                .ToArray());

        var rendered = DatabaseInitializationOptionsParser.RenderSchema(
            "__DASHBOARD_IDENTITY_ENABLED__|__DASHBOARD_IDENTITY_NAME__|" +
            "__DASHBOARD_IDENTITY_SID_HEX__",
            options);

        Assert.Equal(
            $"1|dashboard|{Convert.ToHexString(dashboardClientId.ToByteArray())}",
            rendered);
    }

    [Fact]
    public void RenderSchema_DisablesDashboardPrincipalWhenIdentityIsOmitted()
    {
        var options = DatabaseInitializationOptionsParser.Parse(RequiredArguments());

        var rendered = DatabaseInitializationOptionsParser.RenderSchema(
            "__DASHBOARD_IDENTITY_ENABLED__|__DASHBOARD_IDENTITY_NAME__|" +
            "__DASHBOARD_IDENTITY_SID_HEX__",
            options);

        Assert.Equal(
            "0|endpoint-data-sprawl-dashboard-not-configured|" +
            Convert.ToHexString(Guid.Empty.ToByteArray()),
            rendered);
    }

    private static string[] RequiredArguments() =>
    [
        "--server",
        "example",
        "--database",
        "example",
        "--worker-identity-name",
        "worker",
        "--worker-identity-client-id",
        "11111111-1111-1111-1111-111111111111",
        "--schema",
        "schema.sql",
    ];
}
