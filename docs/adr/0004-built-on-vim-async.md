# Built on vim.async, which requires Neovim nightly

`session:prompt()` returns a `vim.async` task, and closing the task stops the reply. This gives plugins cancellation and structured concurrency from Neovim itself. The cost is that the SDK requires Neovim 0.13-dev until `vim.async` ships in a release.

Events and handlers are the base API. `session:ask()` is a thin wrapper for code that reads better top to bottom, and returns `reply, err` where `vim.async.await` would raise.

## Considered options

- **Callbacks only:** rejected. Every plugin would write its own cancellation
- **A coroutine library such as plenary.async or nio:** rejected. It adds a dependency for something Neovim is about to provide
