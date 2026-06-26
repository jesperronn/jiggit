# Jira Endpoints Cheat Sheet

This is the current Jira REST surface used by `jiggit`.

## Config

Copy the shared values from TOML into a portable script:

```toml
[jira]
base_url = "https://jira.example.com"
bearer_token = "op://JIRA_API_TOKEN_NINE_JRJ"

[project_a]
jira_project_key = "JIRA"
```

Recommended portable constants:

```bash
readonly JIRA_BASE_URL="https://jira.example.com"
readonly JIRA_PROJECT_KEY="JIRA"
readonly JIRA_API_TOKEN_REF='op://JIRA_API_TOKEN_NINE_JRJ'
readonly JIRA_EXAMPLE_ISSUE_KEY="JIRA-123"
readonly JIRA_EXAMPLE_RELEASE_NAME="Api-server_1.2.0"
readonly JIRA_PROJECT_NUMERIC_ID="10000"
```

## Read Endpoints

`GET /rest/api/2/myself`

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/myself"
```

`GET /rest/api/2/project/{projectKey}`

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/project/$JIRA_PROJECT_KEY"
```

`GET /rest/api/2/project/{projectKey}/versions`

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/project/$JIRA_PROJECT_KEY/versions"
```

`GET /rest/api/2/issue/{issueKey}?fields=summary,status,labels,fixVersions`

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/issue/$JIRA_EXAMPLE_ISSUE_KEY?fields=summary,status,labels,fixVersions"
```

`GET /rest/api/2/search?jql=...&fields=summary,status,labels,fixVersions`

Release search:

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/search?jql=project%20%3D%20%22$JIRA_PROJECT_KEY%22%20AND%20%28fixVersion%20%3D%20%22$JIRA_EXAMPLE_RELEASE_NAME%22%20OR%20affectedVersion%20%3D%20%22$JIRA_EXAMPLE_RELEASE_NAME%22%29%20ORDER%20BY%20key%20ASC&fields=summary,status,labels,fixVersions"
```

Open issues:

```bash
curl -sSf -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  "$JIRA_BASE_URL/rest/api/2/search?jql=project%20%3D%20%22$JIRA_PROJECT_KEY%22%20AND%20statusCategory%20%21%3D%20Done%20ORDER%20BY%20updated%20DESC&fields=summary,status,labels,fixVersions&maxResults=10"
```

## Write Endpoints

`POST /rest/api/2/issue`

```bash
curl -sSf -X POST \
  -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/2/issue" \
  --data '{
    "fields": {
      "project": { "key": "'"$JIRA_PROJECT_KEY"'" },
      "issuetype": { "name": "Task" },
      "summary": "Example summary",
      "description": "Example description"
    }
  }'
```

`PUT /rest/api/2/issue/{issueKey}`

```bash
curl -sSf -X PUT \
  -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/2/issue/$JIRA_EXAMPLE_ISSUE_KEY" \
  --data '{
    "update": {
      "fixVersions": [
        { "add": { "name": "'"$JIRA_EXAMPLE_RELEASE_NAME"'" } }
      ]
    }
  }'
```

`POST /rest/api/2/version`

```bash
curl -sSf -X POST \
  -H "Authorization: Bearer $(op read 'op://JIRA_API_TOKEN_NINE_JRJ')" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/2/version" \
  --data '{
    "projectId": '"$JIRA_PROJECT_NUMERIC_ID"',
    "name": "'"$JIRA_EXAMPLE_RELEASE_NAME"'",
    "archived": false,
    "released": false
  }'
```

## Portable Script

Use [bin/adhoc/jira_endpoint_smoke.sh](/Users/jesper/src/jiggit/bin/adhoc/jira_endpoint_smoke.sh) for a movable probe script with:

- constants at the top
- `op://...` token support via `op read`
- dry-run output with redacted auth
- commands for every endpoint listed above
