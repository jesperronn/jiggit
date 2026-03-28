# Jiggit V2 Roadmap

## Deferred From V1

### Multiple Jira Instances
Purpose:
Support more than one Jira installation while keeping the project model understandable.

Why deferred:
- v1 intentionally supports one shared Jira for all configured projects
- the current CLI and config model are simpler and easier to debug with one Jira
- multi-Jira adds config indirection, auth complexity, and more failure modes

Planned direction:
- support multiple named Jira configs such as `jira_a` and `jira_b`
- let each project reference one named Jira config
- allow optional per-project Jira auth overrides when a shared named config is not enough
- keep a clear default so projects without an explicit Jira reference still work

Possible config shape:

```toml
[jira.jira_a]
base_url = "https://jira-a.example.com"
bearer_token = "token-a"

[jira.jira_b]
base_url = "https://jira-b.example.com"
bearer_token = "token-b"

[project_a]
repo_path = "~/src/project_a"
jira = "jira_a"
jira_project_key = "JIRA"

[project_b]
repo_path = "~/src/project_b"
jira = "jira_b"
jira_project_key = "OTHER"
```

Open design questions:
- should the default shared Jira stay available alongside named Jira configs
- how should `doctor`, `jira-check --all`, and `overview` group or label projects that use different Jira instances
- how should secrets be layered between repo config, user config, and env var overrides
- whether a project should be allowed to override only auth, only base URL, or both

Success criteria:
- Jira-backed commands transparently resolve the correct Jira instance per project
- `doctor` and `jira-check` clearly show which Jira instance each project is using
- failures remain understandable when several Jira instances are configured
