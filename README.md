# jiggit

Smart Jira + Git = Jiggit -- Clever release insights for Jira and Git, all in one place.

Command-line tool for connecting git history, deployed versions, and Jira release data across multiple projects and environments.

## Getting Started

Install with the public one-liner:

`curl -fsSL https://raw.githubusercontent.com/jesperronn/jiggit/main/bin/install | bash`

1. Add curated project config in `config/` or `~/.jiggit/config/`, and shared user Jira settings in `~/.jiggit/config.toml`.
2. Run `bash bin/lint` to verify shell syntax and lint status.
3. Run `bash bin/test` to verify the current test suite.
4. Run `bash bin/setup` if you want the current checkout exposed as a single `jiggit` symlink on your shell `PATH`.
5. Use `bash bin/jiggit explore --dry-run --verbose <dir> ...` to inspect candidate repos before writing discovery output.
6. Run `bash bin/jiggit explore <dir> ...` interactively to review and append discovered entries one by one, or use `--append` / `--replace` for non-interactive flows.

Initial bootstrap contents:
- `docs/jiggit-plan.md` contains the current project plan
- `bin/` contains helper scripts copied from an earlier project for reuse/adaptation
- `config/` is reserved for curated project config and examples
- `test/` and `fixtures/` are reserved for shell tests and sample payloads

Copied scripts are starting points only and should be adapted to fit `jiggit`'s command model.

Current commands:
- `jiggit explore [--verbose] [--dry-run] <dir> [<dir> ...]`
- `jiggit env-versions [<project|path>] [--verbose]`
- `jiggit env-diff [<project|path>] --base <env|git-ref> [--target <env|git-ref>] [--verbose]`
- `jiggit doctor [--ignore-failures] [<project|path> ...]`
- `jiggit jira-check [<project|path>] [--all]`
- `jiggit jira-create [<project|path>] [--commit <git-ref>] [--type <issue-type>] [--summary <text>] [--dry-run]`
- `jiggit jira-issues [<project|path>] --release <fixVersion>`
- `jiggit assign-fix-version [<project|path>] --release <fixVersion> [--base <env|git-ref>] [--target <git-ref>]`
- `jiggit release-notes [<project|path>] --target <git-ref|release> [--from-env <env>] [--from <git-ref>]`
- `jiggit releases [<project|path>]`

Global project-scope flags:
- `jiggit --projects=project_a env-diff --base prod`
- `jiggit --projects=project_a,project_b overview`
- `jiggit --all-projects overview`

Project selectors can be:
- a configured project id such as `project_a`
- a repo path such as `.` or `/path/to/repo`
- omitted entirely when you run `jiggit` inside a configured repo

## Project Scope Mode

`jiggit` now has a directory-sensitive default mode:

- inside a configured repo such as `~/src/example/project_a`, commands default to that one project
- outside configured repos, multi-project commands such as `overview` default to all configured projects
- single-project commands such as `env-diff`, `env-versions`, `compare`, `changelog`, `jira-issues`, `releases`, `next-release`, and `assign-fix-version` still expect one project

You can always override the default scope:

- force one or more explicit projects:
  `bash bin/jiggit --projects=project_a,project_b overview`
- break out of current-repo mode for commands that support many projects:
  `bash bin/jiggit --all-projects overview`
- use a path selector directly:
  `bash bin/jiggit env-diff . --base prod`

Project config is loaded from:
- `config/` in the `jiggit` repo
- `~/.jiggit/config.toml`
- `~/.jiggit/config/`
- `config/` inside repos discovered by `jiggit explore`

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

- Discover repositories and generate candidate config:
  `bash bin/jiggit explore --dry-run --verbose ~/src/example`
- Review discovered entries interactively and append selected ones:
  `bash bin/jiggit explore ~/src/example/alpha ~/src/example/project_b`
- Replace the discovery file with fresh findings:
  `bash bin/jiggit explore --replace ~/src/example/alpha ~/src/example/project_b`
- Append more repos to existing discoveries:
  `bash bin/jiggit explore --append ~/src/another-workspace`
- Show deployed versions for a project's configured environments:
  `bash bin/jiggit env-versions project_a --verbose`
- Show deployed versions by running inside the repo:
  `cd ~/src/example/project_a && bash /Users/jesper/src/jiggit/bin/jiggit env-versions --verbose`
- Explain the code difference from a base environment to a target environment:
  `bash bin/jiggit env-diff project_a --base prod --target staging`
- Explain the code difference using the current directory as the project selector:
  `cd ~/src/example/project_a && bash /Users/jesper/src/jiggit/bin/jiggit env-diff --base prod --target dev`
- Compare a base environment against the latest commit on `master`:
  `bash bin/jiggit env-diff project_a --base prod`
- Explain a project explicitly by path:
  `bash bin/jiggit env-diff . --base prod`
- Compare a base environment against an explicit git tag or commitish:
  `bash bin/jiggit env-diff project_a --base prod --target v2.1.0.26`
- Run health checks across all configured projects:
  `bash bin/jiggit doctor`
- Run doctor for one project and keep warnings non-fatal:
  `bash bin/jiggit doctor --ignore-failures project_a`
- Verify Jira auth and project access:
  `bash bin/jiggit jira-check project_a`
- Verify Jira auth and project access across every configured project:
  `bash bin/jiggit jira-check --all`
`env-diff` accepts either configured environment names or git refs for `--base` and `--target`.
When a value could be interpreted as either, the configured environment name wins.
- Detect whether `prod` is behind and suggest the next release version:
  `bash bin/jiggit next-release project_a`
- Add the selected fixVersion to commit-linked Jira issues that are missing it:
  `bash bin/jiggit assign-fix-version project_a --release 1.3.0.0`
- Show a read-only dashboard for the current project or all configured projects:
  `bash bin/jiggit overview`
- Show a dashboard for a chosen subset of configured projects:
  `bash bin/jiggit --projects=project_a,project_b overview`
- Break out of current-repo mode and show all configured projects:
  `bash bin/jiggit --all-projects overview`
- Create a Jira issue draft from the latest commit in a configured repo:
  `bash bin/jiggit jira-create project_b --dry-run`
- Show Jira issues for a release using fuzzy release matching:
  `bash bin/jiggit jira-issues project_a --release 2.1.0.26`
- Generate git-first release notes from prod to a target release:
  `bash bin/jiggit release-notes project_a --from-env prod --target 2.1.0.26`
- Generate release notes against an exact git ref target:
  `bash bin/jiggit release-notes . --from-env prod --target main`
- List Jira releases/fixVersions for a configured Jira project:
  `bash bin/jiggit releases project_a`
- Run the project checks before or after changes:
  `bash bin/lint && bash bin/test`
- Add `jiggit` to your shell PATH if it is not already available:
  `bash bin/setup`
- Install or update `jiggit` from GitHub with one command:
  `curl -fsSL https://raw.githubusercontent.com/jesperronn/jiggit/main/bin/install | bash`

`release-notes` treats an exact local git ref as a git target first.
If a fuzzy Jira release query matches multiple releases, it prints the matches and exits instead of guessing.

`jira-create`, `jira-check`, `jira-issues`, `assign-fix-version`, `releases`, `release-notes`, and `doctor` expect shared Jira settings in TOML config:

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

Right now `jiggit` supports one shared Jira for all configured projects. If Jira config is missing, Jira-backed commands fail clearly during config and doctor checks.
