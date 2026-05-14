# Coverage map -- `swift-logger-splunk 0.1.0`

Each requirement ID locked in
[`Docs/Requirements.md`](../../Docs/Requirements.md) maps to the
test (or tests) that enforce it.

## Payload contract

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `SPLK-1` | Lazy host-side encoding boundary | Implicit -- the type `RemoteDeliveryEntry` carries `Data` payload bytes opaque to the engine. Every integration test in `SplunkRemoteEngineIntegrationTests` exercises this contract by enqueuing host-encoded JSON bytes. |
| `SPLK-2` | HEC envelope construction (metadata stamped, omit nil, sort keys, JSON-escape) | `SplunkHECRequestBodyTests.singleEventWithAllMetadata`, `partialMetadataOmitsNilFields`, `allNilMetadataOmitsSuffix`, `metadataEscapingHandled` |
| `SPLK-3` | Newline-stacked HEC framing (events separated by `0x0A`, not JSON array, one HEC envelope per line) | `SplunkHECRequestBodyTests.multipleEventsAreNewlineStacked`, `singleEventWithAllMetadata` (asserts trailing `0x0A`) |

## `RemoteTransport.sendBatch(_:)` contract

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `SPLK-4` | One HEC request per non-empty `sendBatch(_:)` call; empty batch dispatches no request | `SplunkRemoteTransportTests.sendBatchBuildsOneRequest`, `emptyBatchIsNoOp` |
| `SPLK-5` | One result per input item | `SplunkRemoteTransportTests.sendBatchReturnsOneResultPerInputItem` |
| `SPLK-6` | Input-order preservation | `SplunkRemoteTransportTests.inputOrderingPreservedInRequestBody` |
| `SPLK-7` | 2xx success projection (every item `.success`) | `SplunkRemoteTransportTests.twoXXAllSuccess`, `SplunkRemoteEngineIntegrationTests.flushAllAcceptedAcknowledges` |
| `SPLK-8` | Whole-batch failure projection (throw routes through `classify`) | `SplunkRemoteTransportTests.wholeBatchThrowProjectsThroughClassify`, `SplunkRemoteEngineIntegrationTests.flushTerminalItemsAcknowledges`, `flushRetryableHoldsOutstandingBatch` |

## Classification policy

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `SPLK-9` | Retryable mapping (408 / 429 / 5xx / invalidResponse / unknown / arbitrary error) | `SplunkRemoteTransportTests.classify408Retryable`, `classify429Retryable`, `classify5xxRetryable`, `classifyInvalidResponseRetryable`, `classifyArbitraryErrorRetryable`, `classifyUnknownStatusRetryable` |
| `SPLK-10` | Terminal mapping (401 / 403 / other 4xx) | `SplunkRemoteTransportTests.classify401Terminal`, `classify403Terminal`, `classify400Terminal` |
| `SPLK-11` | Deterministic classification, no queue / export state mutation | Implicit -- `SplunkRemoteTransport.classify(_:)` is a pure function over the input `Result` (no captured queue / export references). Repeated classification invocations for the same result return the same decision; the static `classify(error:)` table-driven tests in `SplunkRemoteTransportTests` exercise the entire mapping table deterministically. Integration tests `flushRetryableHoldsOutstandingBatch` and `flushTerminalItemsAcknowledges` cover the engine-facing acknowledgement decision under both retryable and terminal classifications without classifier side effects. |

## Endpoint trust model

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `SPLK-12` | Direct HEC builds `Authorization: Splunk <token>`; URL is verbatim | `SplunkEndpointTests.hecAuthorizationHeader`, `hecRequestURLIsVerbatim`, `SplunkRemoteTransportTests.hecRequestCarriesSplunkAuthAndJSONContentType` |
| `SPLK-13` | Intake passes Authorization verbatim or omits when `nil`; URL is verbatim | `SplunkEndpointTests.intakeAuthorizationHeaderPassthrough`, `intakeNilAuthorizationOmitsHeader`, `intakeRequestURLIsVerbatim`, `SplunkRemoteTransportTests.intakeRequestCarriesVerbatimAuthorization`, `intakeNilAuthorizationOmitsHeader` |

## Engine lifecycle ownership

| ID | Requirement | Enforcing tests |
| -- | ----------- | --------------- |
| `SPLK-14` | Caller-driven flush lifecycle (no autonomous scheduler) | Implicit -- the package exposes no observer / timer surface on the public engine surface; every integration test in `SplunkRemoteEngineIntegrationTests` drives `engine.flush()` from the test body. |
| `SPLK-15` | Retained outstanding batch reuse across flush passes; no fresh drain while outstanding batch held | `SplunkRemoteEngineIntegrationTests.flushRetryableHoldsOutstandingBatch` |
| `SPLK-16` | Acknowledgement-to-removal lifecycle (ack only on full pass-wide resolution; terminal-only still acks) | `SplunkRemoteEngineIntegrationTests.flushAllAcceptedAcknowledges`, `flushTerminalItemsAcknowledges`, `flushRetryableHoldsOutstandingBatch` |
