# AGENTS

## Development Rules

- Test all new code before finishing work.
- Run `bash bin/test` for the full shell test suite.
- Run `bash bin/lint` for syntax checks and `shellcheck` when available.
- When only one or a few files changed, prefer `bash bin/lint <file> [<file> ...]` instead of linting the whole repository.
- Prefer colocated `*.test.sh` files next to the scripts they cover.
- Keep functions small and comment each function with its purpose so the codebase is easier to port to other languages later.
- Treat `config/` in the repo as curated example or checked-in config, and `~/.jiggit/` as the default user-specific config area.
- For console Markdown output, make headings bold and colored, and prefer blue/cyan/magenta/green for normal informational output so red/orange stay reserved for errors and warnings.
- When highlighting project entries in console output, prefer green bold styling.

## Config Notes

- Curated project config can live in repo-local `config/` and in `~/.jiggit/config/`.
- Shared user Jira config should live in `~/.jiggit/config.toml`.
- Discovery output defaults to `~/.jiggit/discovered_projects.toml`.
- `jiggit explore` may also read `config/` folders inside repos it discovers.

## Standard Commands

- `bash bin/test`
- `bash bin/lint`
