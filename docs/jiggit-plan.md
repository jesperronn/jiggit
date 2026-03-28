# Jiggit V1 Plan

## Summary
Create `jiggit` as a new Bash-first project at `/Users/jesper/src/jiggit`. The project takes inspiration from earlier helper scripts, but the active implementation should live in `jiggit`'s own command modules and TOML-based config.

Two product decisions are locked:
- `jiggit config` replaces `jiggit projects`
- `jiggit` should prefer native `jiggit` command modules over copied legacy helper scripts

## Status Snapshot
### Implemented
- `jiggit config`
- `jiggit explore`
- `jiggit compare`
- `jiggit changelog`
- `jiggit env-versions`
- `jiggit env-diff`
- `jiggit releases`
- `jiggit jira-issues`
- `jiggit jira-check`
- `jiggit doctor`
- `jiggit jira-create`
- `jiggit release-notes`
- `jiggit next-release`
- `jiggit assign-fix-version`
- shared TOML Jira config
- project selection by configured id, repo path, or current configured directory
- global project selectors via `--projects=...`
- explicit multi-project escape hatch via `--all-projects`
- `jira-check --all`
- `repo_path` expansion for `$HOME/...` and `~/...`
- colocated tests, `bin/test`, and `bin/lint`
- legacy shell-era config cleanup
- project ids are used directly as the user-facing names

### Partially implemented
- `jiggit next-release`
  implemented as drift detection, suggested next minor version, unreleased Jira issue review, interactive Jira release creation, and overview integration
  remaining work is mostly presentation polish rather than missing core behavior
- `jiggit doctor`
  implemented as health checks plus a default interactive repair flow for shared Jira config and common per-project gaps
  now repairs shared Jira config, remote URLs, Jira project keys, Jira regexes, environments, version expressions, and environment URLs when it can do so safely
  remaining work is mostly broader heuristics and polish for less common missing fields
- `jiggit explore`
  implemented as interactive discovery and append/replace review with exact TOML previews before writes
  now includes default interactive completion for shared Jira config and common per-project candidate details such as Jira keys, environments, info URLs, and version expressions
  remaining work is mostly deeper heuristics for more inferred project settings
- console styling
  now propagated through the main user-facing subcommands, including `config`, `overview`, `doctor`, `jira-check`, `releases`, `env-versions`, `env-diff`, `compare`, `changelog`, `next-release`, `release-notes`, `jira-issues`, and `explore`
  remaining work is mostly consistency cleanup rather than missing foundation

### Still missing
- no v1 feature gaps are currently tracked here; remaining work is mostly polish, broader repair flows, and roadmap-v2 items

## Bootstrap
Created project structure:
- `README.md`
- `docs/jiggit-plan.md`
- `bin/jiggit`
- `bin/lib/`
- `config/projects.toml`
- `config/projects.toml.example`
- `bin/test`
- `bin/lint`

Bring over inspiration from earlier shell helpers, but adapt rather than blindly copy:
- `bin/git_diff_expr`
  - generalize into reusable git range, issue extraction, and compare helpers
- `bin/lib/common_output.sh`

Tests should live next to the scripts they cover, using `*.test.sh` filenames rather than a separate top-level test directory.

## Test Data Hygiene
- Remove project- or organization-specific references from docs, examples, and test fixtures wherever they are not essential to real functionality.
- For fake/test URLs and sample hostnames, prefer `example.com`.
- For example project names and Jira keys, prefer generic shapes such as `project_a, project_b` and `JIRA-1234`, avoiding real-world identifiers in docs and fixtures.
- Keep project examples vendor-neutral unless the example genuinely needs a specific real-world shape.

## test runner
make sure [PASS] is printed in green and [FAIL] in red for all tests, and that the final test summary is clearly visible.
- shell tests that exercise interactive repair flows must default to non-interactive mode in their shared setup, and only opt into prompting explicitly inside the individual tests that need it, so `bin/test` never blocks waiting on terminal input

## Commands
### Proposed Dashboard Command
Purpose:
Give the user one intuitive way to understand everything important about one project without manually chaining several subcommands.

Suggested name:
- `jiggit overview`

Why this name:
- clearer and friendlier than `all`
- reads well in both single-project and multi-project contexts
- suggests summary and discovery rather than mutation

Proposed behavior:
- By default, gather the useful read-only checks from all commands except `explore`.
- In a configured repo directory, default to a detailed single-project overview.
- Outside any configured repo, default to a compact overview across all configured projects.
- For one project, include sections such as:
  - config summary
  - doctor-style health summary
  - deployed environment versions
  - diff from production to default target
  - release status and suggested next release
  - recent Jira release/fixVersion summary
  - every section should show the subcommand that produced or can further investigate that section, so users learn the CLI while reading the overview
  - each section should carry its own adjacent `next step` or `next steps`, rather than one combined footer for the whole overview
  - when a section reports `missing` or another actionable problem, that same section should include a copy-paste-friendly command for fixing or investigating it
  - for example, if a Jira release version appears missing, show the exact `jiggit next-release ...`, `jiggit releases ...`, or later release-creation command to run
  - if a config value such as `jira_project_key` is missing, the section should also show the config source file that owns the project so the user knows where to edit
- For many projects, prefer a compact summary first and allow a later detailed mode if needed.

Current status:
- implemented as a first cut
- defaults to the current configured repo when run inside one
- defaults to all configured projects otherwise
- supports `--projects=...` to focus the dashboard on one or more configured projects
- supports `--all-projects` to break out of current-repo mode explicitly
- currently includes config summary, environment versions, next-release summary, and compact Jira release summary
- it should evolve from one combined `Next Steps` footer to section-local next-step hints baked into each section and, where appropriate, into the underlying subcommands too
- it should evolve so each section prints the relevant discovery/investigation subcommand, for example `jiggit env-versions ...`, `jiggit next-release ...`, or `jiggit releases ...`
- it should show config-source hints next to missing config fields such as `jira_project_key`, so the user can see which TOML file to edit
- it should evolve richer environment/release diagnostics, including colorized deployment-state cues and unreleased-story summaries
- later iterations can add richer doctor-style checks and more compact all-project rendering

### `jiggit config`
Purpose:
Show the currently configured projects and the settings `jiggit` will use.

Behavior:
- List configured project id, Jira project key, issue-key regexes, repo path, remote URL, and environments.
- Show whether repo path exists locally.
- Show whether repo path and configured remote agree with actual `origin`, when both are present.
- Surface missing or partial config as warnings.

### `jiggit explore <dir> [<dir> ...]`
Purpose:
Scan directories for git repos and generate reviewable project config entries.

Behavior:
- Recursively look for git repositories below the provided directories.
- For each repo, inspect:
  - local path
  - `origin` remote URL
  - repo name
  - available tags
  - sample commit messages
- Infer candidate Jira issue-key patterns by scanning commit history for shapes like:
  - `JIRA-1234`
  - `ISSUE-123`
  - `JIRA-12345`
  - other `[A-Z][A-Z0-9]+-[0-9]+` forms
- Compare discoveries against existing config and mark repos as:
  - already configured
  - newly discovered
  - ambiguous
- Write only newly discovered candidates to `.jiggitrc`/`$HOME/.jiggitrc` or equivalent.
- Do not merge into the primary config automatically.
- Leave placeholders for values that cannot be safely inferred, especially environment URLs.
- Default interactive repair should continue to suggest and write missing config details such as shared Jira settings or environment URLs while reviewing discoveries, always previewing the TOML that would be written first.

Output:
- Markdown summary of findings
- path to the generated discovery file
- warnings for conflicts or ambiguous Jira pattern detection

Workflow:
1. run `jiggit explore ~/src/...`
2. inspect generated candidates
3. edit/fill missing fields
4. copy or merge into main config
5. `git add` the config changes manually

### `jiggit releases [<project|path>]`
Purpose:
List Jira releases/fixVersions for the project.

Behavior:
- Fetch all releases from Jira for the configured Jira project key.
- Show release name, released/archived flags, release date, and any lightweight issue counts if available.
- Sort in a way that makes current and upcoming releases easy to spot.
- Optionally indicate when a release name appears to match an existing git tag.

### `jiggit jira-issues [<project|path>] --release <fixVersion>`
Purpose:
Show Jira issues belonging to a release.

Behavior:
- Accept fuzzy fixVersion matching against Jira releases.
- If exactly one release matches, fetch issues for that release.
- If multiple releases match, print the matches and exit without fetching issues.
- Return at least:
  - issue key
  - title
  - labels
  - status
  - fixVersion(s)
- When an issue has no fixVersion, render `fix_version: MISSING`.
- When an issue has one or more fixVersions, render the actual value(s).
- Keep this command Jira-centric and simple.

### `jiggit jira-check [<project|path>]`
Purpose:
Verify Jira connectivity and project access for one configured project.

Behavior:
- Validate Jira base URL and auth configuration.
- Confirm the configured Jira project key exists and is readable.
- Fetch a lightweight Jira endpoint such as project metadata or versions.
- Return a small diagnostic report suitable for debugging auth and config.
- `--all` should continue through every configured project and only return failure at the end if one or more checks failed.

### `jiggit doctor [<project|path> ...]`
Purpose:
Run end-to-end health checks for configured projects.

Behavior:
- Default to checking all configured projects.
- Support narrowing to one or more explicit projects or repo paths.
- Check local prerequisites such as git, curl, and jq.
- Check repo path, Jira access, info URLs, and releases access where configured.
- Support warning-only mode for optional capabilities so missing prod/release data does not always fail the command.
- Use project issue-key regexes only for validation and enrichment logic elsewhere, not to hide Jira issues here.
- Interactive doctor repair is the default when a TTY is available, and it should continue to expand coverage while always previewing the TOML that would be written first.

### `jiggit env-versions [<project|path>]`
Purpose:
Show deployed version in each configured environment.

Behavior:
- Call each configured environment info URL.
- Extract version using project/env-specific parser settings.
- Normalize versions into comparable git refs when possible.
- Report whether environments match, drift, or are unknown.
- Highlight missing environment versions as warnings, and backport the same logic into `jiggit overview`.
- If production and a lower environment share the same major/minor but differ in build number, highlight the lower-environment version in bold red and mark that a new minor release should be created.
- If production has a lower major/minor than another environment, highlight that as a bold orange pending deployment state.
- In pending-deployment situations, show the unreleased stories/issues for that span and link or point to the relevant release information.
- Include an adjacent investigative command such as `jiggit env-diff ...` or `jiggit next-release ...` when drift is detected.
- When project/path is omitted, resolve the current working directory against configured repos.

### `jiggit env-diff [<project|path>] --base <env|git-ref> [--target <env|git-ref>]`
Purpose:
Explain the code difference between a base deployment and a target deployment or git ref.

Behavior:
- Accept either environment names or git refs for `--base` and `--target`.
- Prefer configured environment names over matching git refs when a value could mean both.
- Resolve environment names to deployed versions through project config.
- Default omitted `--target` to the latest commit on `master`.
- Build a git range from base to target.
- Summarize commits, Jira issues, and conventional-commit groups between them.
- Return explicit “no difference” when both sides resolve to the same version.
- When project/path is omitted, resolve the current working directory against configured repos.

### `jiggit compare [<project|path>] --from <git-ref> --to <git-ref>`
Purpose:
Low-level comparison command for git and Jira-backed diagnostics.

Behavior:
- Normalize refs/tags.
- Use local repo checkout for git operations.
- Show normalized range, commit count, extracted issue keys, and optional compare URL if remote format supports it.
- This is the reusable building block behind release and env comparison commands.

### `jiggit release-notes [<project|path>] --target <git-ref|release> [--from-env <env>] [--from <git-ref>]`
Purpose:
Generate release notes for a target version or release.

Behavior:
- Determine start ref from `--from-env` or explicit `--from`.
- Determine target from an exact local git ref first, otherwise from a uniquely matched Jira release.
- If a fuzzy Jira release query matches multiple releases, print the matches and exit instead of guessing.
- Compute git diff.
- Parse commits using conventional commit groups.
- Extract Jira issue keys via configured regexes.
- Fetch Jira metadata for those issues.
- Include issue fixVersion information in the Jira-enriched output.
- When an issue has no fixVersion, render `fix_version: MISSING`.
- When an issue has one or more fixVersions, render the actual value(s).
- Render grouped Markdown release notes with:
  - issue key
  - title
  - labels
  - status
- Include mismatch sections for:
  - commits without Jira keys
  - issue keys found in commits but suspicious against release/fixVersion
  - Jira release issues missing from git evidence, when applicable

Important rule:
- release notes are git-first, Jira-enriched

### `jiggit changelog [<project|path>] --from <git-ref> --to <git-ref>`
Purpose:
Generate a git-centric changelog grouped by conventional commit type.

Behavior:
- Build diff range
- Group commits by type
- Preserve commits even when no Jira key exists
- Enrich with Jira metadata when issue keys are present
- Less release-specific and less strict than `release-notes`

### `jiggit next-release [<project|path>]`
Purpose:
Detect when a project needs a new release and interactively create the next Jira release version.

Behavior:
- Resolve a deployed base version, defaulting to `prod`.
- Resolve the default target branch/ref from the repo when no explicit target is provided.
- Count commits between base and target.
- Suggest the next release version, defaulting to a minor bump.
- Show unreleased Jira issues/stories for the span between the base and target.
- Reuse shared Jira issue metadata so the next-release report includes current `fixVersions`.
- In the unreleased issue list:
  - highlight resolved issues that already carry the expected upcoming fixVersion in green
  - highlight in-progress issues that carry the expected upcoming fixVersion in aqua/cyan
  - highlight issues missing the expected upcoming fixVersion in bold orange
- Include adjacent next-step commands such as `jiggit releases ...`, `jiggit jira-issues ...`, and later the release-creation / fix-version assignment commands.
- Feed the same richer release-needed diagnostics back into `jiggit overview`.

Behavior:
- Compare the deployed production version against the default development target such as `main`, `master`, or configured head ref.
- Detect when production is behind and newer commits exist.
- Suggest a next release version automatically.
- Default the suggestion to a minor-version bump.
- Current implementation stops here.
- Later let the user review and confirm before creating the Jira release in Jira.

### `jiggit assign-fix-version [<project|path>] --release <fixVersion>`
Purpose:
Add a release fixVersion to Jira issues that appear in the commit span but are missing that fixVersion.

Behavior:
- Build the commit span from production to the chosen development target.
- Extract Jira issues referenced by commits in that span.
- Fetch each issue’s current fixVersions from Jira.
- Show which issues are missing the selected fixVersion.
- Offer an interactive bulk update that adds the fixVersion to those issues.
- Reuse the same issue metadata shape used by `jira-issues` and `release-notes`.

### Shared issue metadata
Purpose:
Make Jira-enriched commands consistent and reusable.

Behavior:
- Shared issue fetch helpers should always include `fixVersions`.
- Any command that shows Jira issues should render `fix_version: MISSING` when no fixVersion exists.
- Any command that shows Jira issues should render actual fixVersion value(s) otherwise.
- When showing unreleased Jira issues relative to the next/upcoming release:
  - resolved issues already carrying the expected fixVersion should be highlighted in green
  - in-progress issues carrying the expected fixVersion should be highlighted in aqua/cyan
  - issues missing the expected fixVersion should be highlighted in bold orange as warnings
- The same issue-state coloring rules should be reused anywhere these unreleased issue lists appear, including `jiggit overview` and later release/deployment diagnostics.
- Section-local next-step hints in `jiggit overview` and related subcommands should be derived from the same shared issue/release metadata so the suggested command matches the actual detected problem.
- Later Jira write helpers should support adding fixVersions to existing issues.

### Project/path selectors
Purpose:
Make commands ergonomic when used from inside checked-out repositories.

Behavior:
- Commands that operate on one project should accept either a configured project id or a repo path such as `.`.
- When no explicit selector is provided, they should try to resolve the current working directory to a configured repo.
- If both a configured project id and a path could match, explicit project ids should win.
- This is implemented for the current single-project command set.

### Global project selection mode
Purpose:
Make it explicit when `jiggit` should stay scoped to the current repo versus operate on several projects at once.

Behavior:
- In a configured repo directory, `jiggit ...` should default to that one project.
- Outside any configured repo, `jiggit ...` should default to all configured projects for commands that support multi-project mode.
- A global selector such as `--projects=project_a,project_b` should override current-directory scoping.
- Add an explicit global escape hatch such as `--all-projects` to break out of single-project directory mode when the user wants multi-project output.
- Multi-project capable commands should render compact summaries first, then deeper per-project sections when useful.

## Configuration
### Main project config
Use a checked-in config file for curated projects. Each project should support:
- one shared Jira config in TOML for now
- project id
- local repo path, optional
- remote URL, optional
- Jira project key
- one or more Jira issue-key regexes
- named environments
- per-environment info URL
- extraction rule for version parsing
- optional tag normalization hints

Follow-up investigation:
- keep config centered on ids instead of duplicated naming fields

Multiple named Jira configs are intentionally deferred to v2. See [roadmap-v2.md](/Users/jesper/src/jiggit/docs/roadmap-v2.md).

### Legacy config cleanup
Completed:
- removed old shell-era config artifacts such as `config/git_diff_expr.example.sh` and `config/projects.sh`
- removed copied standalone helper scripts that were no longer part of the active `jiggit` runtime
- kept `bin/git_diff_expr` because it remains an active runtime dependency

### `bin/setup`
Purpose:
Bootstrap a usable local `jiggit` installation for the current user.

Behavior:
- Keep the command simple and avoid extra mode flags for now.
- First detect whether `jiggit` is already available on `PATH`.
- Do not inspect shell profile files first as the source of truth.
- Only if `jiggit` is not already on `PATH`, detect the user’s current shell and update the relevant startup file for that shell.
- Support common shells such as `bash` and `zsh`.
- Be careful with advanced setups where files such as `.bash_profile` may be symlinks or managed elsewhere.
- Only modify the file that is actually relevant for the detected shell.
- Avoid duplicating PATH entries or shell snippets.
- Report clearly what was changed and whether the user needs to start a new shell or reload config.

Prerequisites:
- required runtime tools: `bash`, `git`, `curl`, `jq`
- optional development tool: `shellcheck`

### Discovery config
Keep discovered projects in a separate generated file.
That file should:
- contain only candidate entries
- be safe to review/edit
- never overwrite curated config silently

### Jira issue-key patterns
Treat issue detection as first-class configuration.

Each project may define several regexes, for example:
- `[A-Z][A-Z0-9]+-[0-9]+`
- `JIRA-[0-9]{3,5}`
- `ISSUE-[0-9]+`

Use these in:
- `explore`
- `compare`
- `release-notes`
- `changelog`

If no project-specific regexes exist, use a generic fallback.

## Save/Bootstrap Deliverables
Create these initial reviewable artifacts in `/Users/jesper/src/jiggit`:
- `docs/jiggit-plan.md` with this plan
- copied helper scripts in `bin/`
- copied shell helper libs in `bin/lib/`
- starter config directory
- colocated `*.test.sh` files next to the relevant scripts
- starter fixtures directory

The helper scripts are saved as adapted starting points for later refactoring into `jiggit`.

## Test Plan
Cover:
- config loading
- multiple Jira regex patterns per project
- repo discovery and deduping
- generated discovery file output
- env version extraction
- ref normalization
- conventional commit grouping
- Jira issue enrichment
- release-note mismatch reporting
- drift detection across environments
- clear failures for missing repo, bad config, missing Jira auth, and bad API responses

Use fixture data for Jira responses, env endpoint JSON, and git log samples so tests stay deterministic.
Prefer colocated shell tests such as `bin/jiggit.test.sh` and `bin/lib/<name>.test.sh` rather than a separate `test/` tree.

## Assumptions
- The new project root is `/Users/jesper/src/jiggit`.
- V1 remains Bash-first and CLI-only.
- Markdown is the only planned output format in v1.
- Git history remains the primary basis for release notes.
- `jiggit config` replaces `jiggit projects`.
- `explore` is a review-first onboarding helper, not a fully automatic config mutator.
- Project-aware commands now resolve a configured repo from the current working directory when no explicit selector is provided.
- Project-aware commands now accept repo paths such as `.` anywhere a project selector is accepted.
