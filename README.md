# ai-hackathon

Agents, skills, hooks and MCP servers that turn **Jira**, **GitLab** and **Plane** data into metrics — packaged to share with the other teams.

## Local environment (Docker)

Requirements: Docker + Compose v2.20+, `make`, `openssl`, **~10 GB of free RAM** for Docker (on WSL2, raise `memory=` in `%UserProfile%\.wslconfig` if needed).

```bash
make up        # generates infra/.env with secrets and starts everything
make status    # checks that the 3 UIs respond
make help      # other commands (jira / gitlab / plane individually, logs, down, nuke)
```

| Tool | URL | First access |
|---|---|---|
| Jira 10.3 LTS | http://localhost:8080 | Setup wizard (database is preconfigured). Requires a free **trial** license: https://my.atlassian.com/license/evaluation → *Jira Software (Data Center)*, using the Server ID shown on screen. |
| GitLab CE 19.5 | http://localhost:8929 | user `root`, password from `make gitlab-password`. SSH on port 2224. First boot takes ~3-5 min. |
| Plane v1.4.3 | http://localhost:8090 | Instance admin at http://localhost:8090/god-mode/ → then create a workspace/project. |

All containers share the `ai-hackathon_default` network; from inside it the services are reachable as `http://jira:8080`, `http://gitlab:8929` and `http://plane-proxy` (handy for MCP servers / collectors running in containers).

### API tokens (next step: metric collectors)

- **Jira**: Profile → *Personal Access Tokens* → `Authorization: Bearer <token>` on `/rest/api/2/...`
- **GitLab**: Preferences → *Access Tokens* (scope `read_api`) → `PRIVATE-TOKEN` header on `/api/v4/...`
- **Plane**: Workspace Settings → *API Tokens* → `X-API-Key` header on `/api/v1/...`

### Layout

```
infra/
  compose.yml        # aggregates the 3 stacks via `include`
  .env.example       # ports, versions, secrets (make setup generates .env)
  jira/compose.yml   # jira + postgres
  gitlab/compose.yml # omnibus in low-memory mode
  plane/compose.yml  # adapted from Plane's official v1.4.3 compose
```

## Claude Code + GitLab MCP

GitLab (18.x+) ships a built-in MCP server at `/api/v4/mcp`. This repo's `.mcp.json` registers it as the `gitlab` server.

On **GitLab CE** the `mcp` scope is not offered for personal access tokens (only `ai_features` shows up in the UI), so authentication is done with **OAuth + dynamic client registration**, which Claude Code handles for you:

1. Start `claude` in this repo and approve the project MCP server when prompted.
2. Run `/mcp` → select `gitlab` → **Authenticate**. A browser tab opens on http://localhost:8929; log in and click **Authorize**.
3. `/mcp` should now show `gitlab · connected`. The token is stored by Claude Code, not in the repo.
4. Use the `gitlab-metrics` subagent (`.claude/agents/gitlab-metrics.md`), e.g. *"use the gitlab-metrics agent to report MR lead time for group X over the last 30 days"*.

Set `GITLAB_URL` to point at another instance (defaults to `http://localhost:8929`).

Troubleshooting: `docker exec gitlab gitlab-rake "gitlab:mcp:verify_setup[<username>]"` runs GitLab's own MCP diagnostics.

## APM package (deliverable)

The shareable package lives in [`apm/`](apm/README.md), a git submodule of https://github.com/luizvnasc/ai-hackathon-apm (clone with `git clone --recurse-submodules`, or run `git submodule update --init` in an existing clone). Teams install it with `apm install luizvnasc/ai-hackathon-apm` and run its setup wizard (`/setup-mcp` in Claude Code, or `apm/scripts/setup-mcp.sh`) to register the GitLab MCP server against their own instance.
