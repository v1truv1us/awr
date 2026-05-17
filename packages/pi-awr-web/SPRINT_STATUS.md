# Sprint Status

## Completed

- Created `pi-awr-web`, a pi package that ships a `web` extension tool
- Wired the tool to AWR for `visit`, `tools`, and `call`
- Added degraded `visit` fallback behavior
- Added JSONL problem logging plus `/awr-status`, `/awr-problems`, and `/awr-note`
- Added unit tests for config, fallback parsing, AWR envelope parsing, and logging (10 tests)
- Added integration tests against the live AWR binary and mock fixture (7 tests)
- Installed into pi config (`~/.pi/agent/settings.json`)
- Verified all three actions work end-to-end through pi
- Verified fallback works when AWR binary is unavailable

## Test results

- 17 tests passing (10 unit + 7 integration)
- typecheck clean
- lint clean

## Next logical step

- Decide whether `tools`/`call` should gain a non-AWR fallback or stay AWR-only with better diagnostics
- Consider publishing as a git-installable pi package
