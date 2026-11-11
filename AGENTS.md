# AGENTS

jiggit: a bash CLI that connects git history, deployed versions and Jira release data across projects.

## Definition of done

`bin/workflows` lists the commands. Run `bin/lint` then `bin/test` (bash 4+) and show the output before saying "done". When only some files changed, pass them: `bin/lint FILE...`, `bin/test FILE...`.

## Conventions

- Conventional commits (`feat:`, `fix:`, `docs:` ...), one focused commit per user-visible feature, fix or docs change; keep unrelated cleanup separate. Stage only the files you changed.
- Tests are colocated `*.test.sh` next to the script, executable, built on `bin/lib/bash_test.sh` ([bash-shell-testing](~/.agents/skills/bash-shell-testing/SKILL.md)). Every assertion prints `[PASS]`.
- `bin/test` keeps file headers bold and colored and relies on colored `[PASS]`/`[FAIL]` markers.
- Keep functions small and comment each one with its purpose, so the code ports to other languages.
- On macOS use `gsed`, not BSD `sed`.
- Console Markdown: headings bold and colored; blue/cyan/magenta/green for normal output, red/orange only for errors and warnings; project entries green bold.
- `config/` in the repo is curated example config; `~/.jiggit/` is the user-specific area (README, "Project config is loaded from").

## Hard rules

- Never push or tag by hand: `bin/release` tags locally and pushes only after its prompt.
- Never commit `.env` or `bin/adhoc/_jira_variables.sh` (both gitignored), and never run `bin/adhoc/` probes unprompted: they call a real Jira.

## Docs

- [README.md](README.md): install, commands, config locations (`~/.jiggit/config.toml`, `config/`, `~/.jiggit/discovered_projects.toml`).
- [docs/](docs): plan, roadmap and Jira endpoint notes.
- Release: `bin/changelog next|render` previews, `bin/release [vX.Y.Z]` releases.
