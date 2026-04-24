# jiggit

Smart Jira + Git = Jiggit -- Clever release insights for Jira and Git, all in one place.

Command-line tool for connecting git history, deployed versions, and Jira release data across multiple projects and environments.

## Getting Started

Install with the public one-liner:

`curl -fsSL https://raw.githubusercontent.com/jesperronn/jiggit/main/bin/install | bash`

1. Add curated project config in `config/` or `~/.jiggit/config/`, and shared user Jira settings in `~/.jiggit/config.toml`.
2. Run `bin/lint` to verify shell syntax and lint status.
3. Run `bin/test` to verify the current test suite.
4. Run `bin/setup` if you want the current checkout exposed as `jiggit` on your shell `PATH`.
5. Use `jiggit setup explore --dry-run --verbose <dir> ...` to inspect candidate repos before writing discovery output.
6. Run `jiggit setup explore <dir> ...` interactively to review and append discovered entries one by one, or use `--append` / `--replace` for non-interactive flows.

Initial bootstrap contents:
- `docs/jiggit-plan.md` contains the current project plan
- `bin/` contains helper scripts copied from an earlier project for reuse/adaptation
- `config/` is reserved for curated project config and examples
- `test/` and `fixtures/` are reserved for shell tests and sample payloads

Copied scripts are starting points only and should be adapted to fit `jiggit`'s command model.

Current commands:
- `jiggit setup`
- `jiggit setup jira [<jira-name>]`
- `jiggit setup explore [--verbose] [--dry-run] <dir> [<dir> ...]`
- `jiggit env-versions [<project|path>] [--verbose]`
- `jiggit changes [<project|path>] --base <env|git-ref> [--target <env|git-ref>] [--verbose]`
- `jiggit changes [<project|path>] --from <git-ref> [--to <git-ref|release>] [--verbose]`
- `jiggit changes [<project|path>] --from-env <env> [--to <git-ref|release>] [--verbose]`
- `jiggit dash [<project|path> ...] [--verbose]`
- `jiggit doctor [--ignore-failures] [<project|path> ...]`
- `jiggit jira-check [<project|path>] [--all]`
- `jiggit jira-create [<project|path>] [--commit <git-ref>] [--type <issue-type>] [--summary <text>] [--dry-run]`
- `jiggit assign-fix-version [<project|path>] --release <fixVersion> [--base <env|git-ref>] [--target <git-ref>]`
- `jiggit releases [<project|path>]`

Global project-scope flags:
- `jiggit --projects=project_a changes --base prod`
- `jiggit --projects=project_a,project_b dash`
- `jiggit --all-projects dash`

Project selectors can be:
- a configured project id such as `project_a`
- a repo path such as `.` or `/path/to/repo`
- omitted entirely when you run `jiggit` inside a configured repo

## Project Scope Mode

`jiggit` now has a directory-sensitive default mode:

- inside a configured repo such as `~/src/example/project_a`, commands default to that one project
- outside configured repos, multi-project commands such as `dash` default to all configured projects
- single-project commands such as `changes`, `env-versions`, `releases`, `next-release`, and `assign-fix-version` still expect one project

You can always override the default scope:

- force one or more explicit projects:
  `jiggit --projects=project_a,project_b dash`
- break out of current-repo mode for commands that support many projects:
  `jiggit --all-projects dash`
- use a path selector directly:
  `jiggit changes . --base prod`

Project config is loaded from:
- `config/` in the `jiggit` repo
- `~/.jiggit/config.toml`
- `~/.jiggit/config/`
- `config/` inside repos discovered by `jiggit setup explore`

Generated discovery output defaults to `~/.jiggit/discovered_projects.toml`.

Shared settings such as the single supported Jira host can live in
[projects.toml](/Users/jesper/src/jiggit/config/projects.toml), while user-specific secrets and personal Jira overrides are better kept in `~/.jiggit/config.toml`.

Environment version config can be declared per project in TOML:

```toml
[project_a]
repo_path = "/path/to/project_a"
remote_url = "ssh://git@example.com/project_a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "staging", "dev"]
info_version_expr = "jq -r '.git.branch'"

[project_a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
staging = "https://staging.project-a.example.com/actuator/info"
dev = "https://dev.project-a.example.com/actuator/info"
```

## Typical Usecases

### Daily Flow

- Check the current project or all configured projects:
  `jiggit dash`
- See deployed versions for one project:
  `jiggit env-versions project_a --verbose`
- Explain what changed since `prod`:
  `jiggit changes project_a --base prod`
- Run health checks:
  `jiggit doctor`

### Release Flow

- Detect whether `prod` is behind and suggest the next release:
  `jiggit next-release project_a`
- Add a missing fixVersion to commit-linked issues:
  `jiggit assign-fix-version project_a --release 1.3.0.0`
- Show release-oriented changes and Jira issues for a release:
  `jiggit changes project_a --from-env prod --to 2.1.0.26`

### Setup And Discovery

- Add `jiggit` to your shell `PATH`:
  `bin/setup`
- Discover candidate repos before writing config:
  `jiggit setup explore --dry-run --verbose ~/src/example`
- Review and append discoveries interactively:
  `jiggit setup explore ~/src/example/alpha ~/src/example/project_b`
- Replace the discovery file with fresh findings:
  `jiggit setup explore --replace ~/src/example/alpha ~/src/example/project_b`

### Jira-Only Checks

- Verify Jira auth and project access:
  `jiggit jira-check project_a`
- Repair or create Jira auth config:
  `jiggit setup jira`
- Create a Jira issue draft from the latest commit:
  `jiggit jira-create project_b --dry-run`
- List Jira releases/fixVersions:
  `jiggit releases project_a`

`changes` accepts either configured environment names or git refs for `--base` and `--target`.
When a value could be interpreted as either, the configured environment name wins.

Additional workflows are easy to discover from each command's built-in next-step hints.

- Run the project checks before or after changes:
  `bin/lint && bin/test`
- Install or update `jiggit` from GitHub with one command:
  `curl -fsSL https://raw.githubusercontent.com/jesperronn/jiggit/main/bin/install | bash`

`changes --to` treats an exact local git ref as a git target first.
If a fuzzy Jira release query matches multiple releases, it prints the matches and exits instead of guessing.

`jira-create`, `jira-check`, `assign-fix-version`, `releases`, `changes`, and `doctor` expect shared Jira settings in TOML config:

```toml
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"
```

Or basic auth:

```toml
[jira]
base_url = "https://jira.example.com"
user_email = "user@example.com"
api_token = "token"
```

Projects can keep using the default `[jira]` block, or point at named Jira entries when they need more than one Jira host or auth setup.
