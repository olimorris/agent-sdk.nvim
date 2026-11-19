---
name: transport-parity
description: Check that a plugin sees the same thing from an HTTP adapter and an ACP agent when a prompt fails, is stopped or is cut off
disable-model-invocation: true
---

# Transport parity

A plugin can't know whether the user picked an HTTP adapter or an ACP agent, so it has to survive the same failures the same way on both (see [ADR 0003](../../../doc/adr/0003-one-session-api-for-http-and-acp.md)). This skill runs every failure case through both transports and compares the **plugin's view**: everything a plugin can observe through the public API in `doc/INTEGRATING.md`.

## Steps

### 1. Write a parity test for each case

For every case in [Failure cases](#failure-cases), add a pair of tests to `tests/test_parity.lua`: one through `tests/fake_http.lua`, one through `tests/fake_acp.lua`. Drive both through `sdk.session()` and `session:prompt()`, as a plugin would, with a recorder on every handler.

Use the fakes, not `agent_sdk.test`. The test adapter scripts events above the transport, so a failure in curl or the agent's process never reaches it.

Each test asserts the plugin's view in full:

- **Events**: the ordered list of handlers called. Exactly one `done` or one `error`, and nothing after it
- **Error payload**: `message`, `cancelled` and `prompt`
- **History**: `session.messages` before and after. A failed prompt adds nothing ([ADR 0008](../../../doc/adr/0008-a-failed-prompt-adds-nothing-to-the-history.md))
- **Afterwards**: what the next `session:prompt()` does
- **Leftovers**: curl jobs still running, agent processes still alive, and anything written outside the handlers (`vim.notify`, `print`, `error()` reaching the user)

Done when every case has both tests and every test asserts all five.

### 2. Run them

```sh
make test_file FILE=tests/test_parity.lua
```

Leave failing tests red. This skill finds divergence and doesn't fix the SDK.

Done when the suite has run and you hold the result of every test.

### 3. Classify every difference

Compare each HTTP test with its ACP twin, field by field. Each difference is one of:

- **Documented**: listed under "HTTP and ACP" in `doc/INTEGRATING.md`. Not a finding
- **Divergence**: the plugin would see something different and the docs don't say so
- **Broken on both**: both sides match, but break a rule under "Rules" in `doc/INTEGRATING.md`

Done when every difference, and every red test, has one of these three labels.

### 4. Report

One table, with a row per case:

| Case | HTTP | ACP | Label |
| --- | --- | --- | --- |

Below it, for each divergence and each broken-on-both, one line saying what a plugin author would hit, written as a real scenario ("the chat buffer keeps its spinner forever because no `error` arrives"), and the test that shows it.

End with the questions the user has to decide, one line each: for each divergence, whether the SDK should change or `doc/INTEGRATING.md` should document it.

## Failure cases

| Case | HTTP | ACP |
| --- | --- | --- |
| Can't connect | curl fails before any output (`fake.fail`) | The agent's command doesn't exist, or exits during `initialize` |
| Provider refuses the prompt | A 4xx or 5xx body (`tests/stubs/anthropic_error.txt`) | A JSON-RPC error answering `session/prompt` |
| Cut off mid-reply | curl exits with text already streamed | `agent.exit()` with text already streamed |
| Garbage on the wire | A malformed SSE chunk | A line on stdout that isn't JSON |
| Model refuses | `tests/stubs/anthropic_refusal.txt` | A `refusal` stop reason |
| Hangs | Headers arrive, then nothing | The agent never answers `session/prompt` |
| Stopped mid-text | Close the task `session:prompt()` returned | Same |
| Stopped mid-tool call | Close the task while `on.request.tool_call` is unanswered | Close the task while `on.request.permission` is unanswered |
| Closed mid-reply | `session:close()` while streaming | Same |
| Handler throws | `on.text` raises an error | Same |
| Handler never answers | `on.request.tool_call` never calls `respond()` | `on.request.permission` never calls `respond()` |
| Prompt while busy | A second `session:prompt()` before `done` | Same |
| Prompt after a failure | Any case above, then a fresh prompt | Same. Expect `error` on ACP after the process exits, which is documented |

When a case can't be provoked through a fake, extend the fake rather than skipping the case, and say so in the report.
