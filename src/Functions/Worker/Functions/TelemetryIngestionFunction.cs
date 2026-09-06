using Azure.Messaging.ServiceBus;
using LogCollector.Worker.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace LogCollector.Worker.Functions;

/// <summary>
/// Service Bus triggered ingestion worker.
/// </summary>
/// <remarks>
/// <c>autoCompleteMessages</c> is disabled in <c>host.json</c> so this function
/// decides each message's fate explicitly:
/// <list type="bullet">
///   <item>success → <c>CompleteMessageAsync</c>;</item>
///   <item>permanent failure → <c>DeadLetterMessageAsync</c> with a reason, so a
///   poison payload leaves the queue immediately instead of burning ten delivery
///   attempts and ten ingestion calls;</item>
///   <item>transient failure → rethrow, abandoning the lock for redelivery.</item>
/// </list>
/// </remarks>
public sealed class TelemetryIngestionFunction
{
    private readonly TelemetryIngestionProcessor _processor;
    private readonly ILogger<TelemetryIngestionFunction> _log;

    public TelemetryIngestionFunction(TelemetryIngestionProcessor processor, ILogger<TelemetryIngestionFunction> log)
    {
        _processor = processor;
        _log = log;
    }

    [Function("IngestTelemetry")]
    public async Task Run(
        [ServiceBusTrigger("%ServiceBus:QueueName%", Connection = "ServiceBus")]
        ServiceBusReceivedMessage message,
        ServiceBusMessageActions messageActions,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(message);
        ArgumentNullException.ThrowIfNull(messageActions);

        var pointer = TelemetryIngestionProcessor.TryParsePointer(message.Body.ToString(), out var parseReason);
        if (pointer is null)
        {
            _log.LogError("Dead-lettering malformed pointer message {MessageId}: {Reason}", message.MessageId, parseReason);
            await messageActions
                .DeadLetterMessageAsync(message, null, "MalformedPointer", Truncate(parseReason), ct)
                .ConfigureAwait(false);
            return;
        }

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"] = pointer.CorrelationId,
            ["TableName"] = pointer.TableName,
        });

        var outcome = await _processor.ProcessAsync(pointer, ct).ConfigureAwait(false);

        if (!outcome.Ok && outcome.Permanent)
        {
            _log.LogError(
                "Dead-lettering unprocessable payload for correlationId={CorrelationId}: {Reason}",
                pointer.CorrelationId, outcome.Reason);
            await messageActions
                .DeadLetterMessageAsync(message, null, "UnprocessablePayload", Truncate(outcome.Reason), ct)
                .ConfigureAwait(false);
            return;
        }

        await messageActions.CompleteMessageAsync(message, ct).ConfigureAwait(false);
    }

    // Service Bus caps dead-letter description length; truncate rather than fail
    // the dead-letter call itself.
    private static string Truncate(string? reason)
        => string.IsNullOrWhiteSpace(reason)
            ? "unspecified"
            : reason.Length <= 4000 ? reason : reason[..4000];
}
