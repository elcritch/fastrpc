# Repository Guidelines

## Project Structure & Module Organization
- `src/`: Library source. Entry is `src/fastrpc.nim`; modules live under `src/fastrpc/` (e.g., `server/`, `socketserver.nim`, `serverutils.nim`, `utils/`, `cli_utils/`).
- `tests/`: Unit and integration examples. Integration tools live in `tests/integration/` (e.g., `fastrpcserverExample.nim`, `fastrpccli.nim`).
- `deps/`: Dependencies installed by Atlas; paths wired via `nim.cfg`.
- Config: `nim.cfg` (compiler paths/flags), `config.nims` (handy build/test tasks).

## Build, Test, and Development Commands
- Install dependencies: `atlas install` (populates `deps/` per `nim.cfg`).
- Build examples: `nim c tests/integration/fastrpcserverExample.nim`
- Run an example: `nim c -r tests/integration/fastrpccli.nim`
- Run a single test: `nim c -r tests/test1.nim`
- Run full test sweep: `nim test` (invokes the `test` task from `config.nims`).

## Coding Style & Naming Conventions
- Indentation: 2 spaces; UTF‑8 files; wrap at ~100 cols.
- Naming: procs/vars `lowerCamelCase`, types `PascalCase`, exported symbols `*` suffix.
- Formatting: use `nimpretty --backup:off <file.nim>` before PRs.
- Compiler hygiene: build with `--styleCheck:hint --warning[UnusedImport]:on` when feasible.

## Testing Guidelines
- Framework: Nim `unittest` for unit tests; integration examples compile and run binaries.
- Location: place tests in `tests/`; name files `t*.nim` to be picked up by the `test` task.
- Running: prefer `nim test` for the full sweep; keep tests deterministic and fast.

## Commit & Pull Request Guidelines
- Commits: imperative, concise subjects (≤ 50 chars), body explains what/why.
  - Example: `server: fix UDP recv buffer sizing`
- PRs: clear description, link issues, summarize behavior change, include run/test commands and any protocol impacts. Add logs or CLI output where helpful.

## Security & Configuration Tips
- Flags: default `nim.cfg` enables `--threads:on` and debug defines; use `-d:release` for performance runs.
- Dependencies: vendored in `deps/`; avoid editing directly—update via upstream if needed.
- Networking: examples open UDP on `0.0.0.0:5656`; bind to restricted interfaces when testing on shared hosts.
