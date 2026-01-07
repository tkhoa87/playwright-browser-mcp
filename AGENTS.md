# Repository Guidelines

## Project Overview

This repo is a lightweight wrapper around `@playwright/mcp` that exposes Playwright browser capabilities via an MCP server. The wrapper is implemented as a shell script (`main.sh`) that executes the server through `npx`, passing through any CLI args.

## Project Structure & Module Organization

- `main.sh` is the entrypoint for the MCP server wrapper; it shells out to `@playwright/mcp` via `npx`.
- `package.json` defines the CLI name and dependency; `package-lock.json` pins versions.
- `node_modules/` is vendor output (do not edit by hand).

## Build, Test, and Development Commands

- `npm install` — installs dependencies used by the CLI wrapper.
- `npm pack` — produces a tarball to verify the package contents (`main.sh` only).
- `./main.sh -- <args>` — runs the MCP server wrapper directly.
- `npx playwright-browser-mcp -- <args>` — runs the installed CLI (after `npm install` or when published).

### Prerequisites

- Node.js and npm must be installed.

### Usage

Run the MCP server wrapper directly:

```bash
./main.sh [arguments]
```

Any arguments are passed through to the underlying `@playwright/mcp` server.

Run the installed CLI after `npm install` (or when published):

```bash
npx playwright-browser-mcp -- <args>
```

## Coding Style & Naming Conventions

- Shell scripts use Bash with strict mode (`errexit`, `pipefail`, `nounset`).
- Prefer small, readable functions if the script grows; keep comments brief and purposeful.
- Indentation: 2 spaces in shell continuations to match `main.sh`.
- Naming: lowercase filenames with hyphens (e.g., `main.sh`); CLI name matches package name.

## Testing Guidelines

- No automated tests are currently defined.
- If you add tests, document the framework and provide a `npm test` script in `package.json`.

## Commit & Pull Request Guidelines

- There is no commit history yet, so no established commit message convention.
- Use concise, imperative subjects (e.g., “Add README”); include scope if helpful (e.g., “cli: …”).
- PRs should include a short description of the change, how to run it locally, and any risks.

## Security & Configuration Tips

- `@playwright/mcp` is installed via `npx`; consider pinning a specific version in `package.json` if reproducibility is required.
- Pass configuration through CLI args (e.g., `./main.sh -- --help` to inspect options).
