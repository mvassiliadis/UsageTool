# Checkpoint 1 review disposition

This document dispositions every finding in `/tmp/usagetool-opus-review-1.md` against the working tree after remediation. “Resolved” means implemented and covered by deterministic local validation where practical.

## Blockers

1. **Store never started — resolved.** `UsageToolApplicationDelegate.applicationDidFinishLaunching` starts the shared store exactly once. Production startup is intentionally suppressed in an XCTest host so tests never inspect real provider state.
2. **Codex child outlives quit — resolved.** The app delegate synchronously terminates the registered child PID on every application termination path, with an `atexit` backstop. Normal disconnect retains the graceful terminate/KILL fallback. A process-backed unit test verifies synchronous termination.
3. **Codex read pipes leaked — resolved.** stdout/stderr pipes are retained, their handlers are cleared, both read handles are closed, and stream/task state is finished during disconnect.
4. **JSONL chunks could reorder — resolved.** stdout feeds one bounded `AsyncStream<Data>` and one long-lived consumer. The fake app-server test splits the initialize response across writes and completes the full handshake/read sequence.
5. **Claude reinstall lost the chain — resolved.** Reinstall decodes `--chain-base64`, preserves the original manifest and backup identity, and never replaces `previousStatusLine` with UsageTool’s own command. The install/restore test now installs twice and verifies one backup plus restoration.
6. **Clock erased loading/network errors — resolved.** Only connected, stale, and partial states are re-resolved. Loading, network, credential, auth, unavailable, and disconnected states are preserved; covered by store-state tests.
7. **`sk-or-` prefix blocked save — resolved.** The prefix is a non-blocking UI hint only. `/api/v1/key` and `is_management_key` are authoritative; a non-prefixed mocked management key is accepted and stored only after validation.
8. **No OpenRouter tests — resolved.** Mocked `URLProtocol` coverage now includes management-key validation-before-storage, expiry/expiring state, expired-401/403 classification, no auth retry, `Retry-After`, retry count, coalescing, exact `Decimal` credit arithmetic, and the no-percentage rule.

## Improvements

9. **Chained output pipe stall/EPIPE — resolved.** The helper drains stdout concurrently, uses throwing `FileHandle` writes, enforces TERM/KILL deadlines without the former busy-wait, caps retained output, and is process-tested with a 200 KB chained producer.
10. **UsageTool line disappeared when chaining — resolved.** The helper emits the existing line followed by the UsageTool line; end-to-end output is asserted.
11. **One-window Codex report was permanently partial — resolved.** Codex requirements derive from the windows actually reported; only Claude requires the named 5h/7d rows. Tests distinguish the two providers.
12. **Refresh cadence changes were inert — resolved.** The picker reschedules the cadence task immediately. The loop exits when the store deallocates and scheduled refresh does not poll a connected Codex process.
13. **Menu-bar preferences were inert — resolved.** Warning symbol, warning color, hide-unavailable, and unavailable `—` behavior are wired into labels/bindings/summary. `!` remains reserved for error/auth/expiry states.
14. **Valid settings without `statusLine` looked corrupt — resolved.** Inspection returns `notInstalled`; covered by a temporary-home test.
15. **No Manual adapter mode — resolved.** The sheet has Guided/Manual segmented modes, valid escaped/selectable JSON, Copy, automatic fallback for invalid/incompatible settings, and consistent refresh interval generation.
16. **Unlocalized domain errors — resolved.** Claude installer/status-line and Keychain errors implement `LocalizedError` with user-facing descriptions.
17. **Offline overwrote disconnected — resolved.** Offline errors apply only to states that represent an active or previously successful integration.
18. **No onboarding empty state — resolved.** The popover uses `ContentUnavailableView`, provider tiles, and the sole `.glassProminent` Open Settings action when no provider has data.
19. **Removal required a manifest — resolved.** Removal can reconstruct the chain and use the latest app-owned backup when the manifest is absent; it still refuses to overwrite a configuration no longer owned by UsageTool. Covered by a manifest-loss test.
20. **Codex decoder was over-strict — resolved.** Missing `resetsAt` preserves the percentage with a nil reset, and an empty window result decodes successfully then maps to a distinct unavailable state. Both are tested.
21. **Retry/notification teardown over-triggered — resolved.** Deterministic auth/config/protocol errors do not reconnect, and malformed update notifications are ignored. The fake server sends one malformed notification before a valid response.
22a. **Shared URL cache — resolved.** The production OpenRouter session is ephemeral with no URL cache.
22b. **Secret materialized for existence — resolved.** `KeychainStore.contains()` uses `SecItemCopyMatching` with `kSecReturnData = false`.
22c. **Resolved Codex path absent from diagnostics — resolved.** The selected executable path is retained and shown in Codex detail diagnostics.
22d. **Provider image rendering intent implicit — resolved.** Provider marks explicitly use `.renderingMode(.original)`.
22e. **Bar track token wrong — resolved.** Normal tracks use `.quaternary`; increased contrast retains the stronger accessible track.
22f. **Claude path hard-coded — resolved.** The selectable detail row uses `store.claudeSnapshotURL.path`.
22g. **Cadence loop could spin after deallocation — resolved.** A missing store returns from the task.
22h. **Compact currency ignored locale — resolved.** Compact formatting uses `NumberFormatter` with the supplied locale, USD placement, localized separators, and a compact multiplier.
22i. **Snapshot watcher lacked debounce — resolved.** File-system events are coalesced with a cancellable 150 ms debounce; the 60-second fallback remains.
22j. **Snapshot fraction noise — resolved.** Sanitized remaining fractions are rounded to six decimal places at the source.

## Opus re-review follow-ups

The complete 329-line re-review at `/tmp/usagetool-opus-review-2.md` approved checkpoint 1 and identified six non-blocking follow-ups. All six have been explicitly closed:

1. **R1, synchronous termination escalation — resolved.** The exit registry sends `SIGTERM`, polls for up to 200 ms, then sends `SIGKILL`. Its regression child deliberately ignores `SIGTERM` and is verified to exit from `SIGKILL`.
2. **R2, registry cleared before child death — resolved.** Normal disconnect no longer clears the PID before termination. The `Process` termination handler owns normal cleanup; the synchronous exit backstop retains the PID throughout the vulnerable interval.
3. **R3, automatic refresh auth gate — resolved.** Deterministic mocked tests cover both 401 and 403: the next automatic refresh performs no request, while an explicit successful manual refresh proceeds and re-enables subsequent automatic refreshes.
4. **R4, manifest-loss reinstall fidelity — resolved.** Reinstall recovers the complete original `statusLine` object and its backup path from the latest owned backup before falling back to a reconstructed command. A temporary-home test preserves custom `refreshInterval` and padding keys through reinstall and removal.
5. **R5, compact currency suffix placement — resolved.** The magnitude suffix is inserted directly after the localized number and before a suffix-positioned currency symbol. `en_US`, `de_DE`, and `fr_FR` outputs are asserted.
6. **R6, non-object Codex JSONL policy — accepted fail-closed by design.** A top-level non-object cannot be a JSON-RPC message. The client treats it as protocol corruption, disconnects, and does not retry-loop; a later user, wake, or network refresh can reconnect. The policy is documented at the parser and covered by reconnect-policy assertions.

The re-review's timing-test risks are also closed. OpenRouter coalescing now uses an explicit blocking gate plus actor-observable waiter count rather than `Thread.sleep`; the process-backed Codex fixture remains timing-independent and is exercised in repeated full-suite runs.

## Validation and residual release checks

- Debug build succeeds with Swift strict concurrency set to `complete`.
- The full suite passes 37/37 tests using temporary homes/paths, mocked URL transport, fake local processes, and non-secret sentinel values.
- Three consecutive iterations pass 111/111 test executions; the formerly sleep-synchronized coalescing test uses an explicit gate.
- No test starts production provider loading; no test reads or mutates real Claude/Codex configuration or real credentials.
- Boundary scans remain clean: the only production request host is `openrouter.ai`; no private endpoints, browser credentials, provider credential files, OAuth/PKCE, model requests, or organization/admin APIs are present.
- **Release-only:** exercise `KeychainStore` from a properly signed distribution build and confirm the data-protection Keychain does not return `errSecMissingEntitlement` (`-34018`). This cannot be made representative under `CODE_SIGNING_ALLOWED=NO` and is not simulated.
- **External compatibility:** Research questions Q1, Q2, Q4, and Q5 still require sanctioned live-account/version checks. Unverified Codex/Claude fallback URLs remain intentionally absent.
