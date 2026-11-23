# ai-hackathon

Agents and skills that turn **Jira**, **GitLab** and **Plane** data into metrics — packaged to share with the other teams.

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
| Plane v1.4.3 | http://localhost:8090 | `make plane` creates the instance admin `root@plane.local`; get its password with `make plane-password`. Log in at http://localhost:8090/god-mode/, then create a workspace/project. |

All containers share the `ai-hackathon_default` network; from inside it the services are reachable as `http://jira:8080`, `http://gitlab:8929` and `http://plane-proxy` (handy for collectors running in containers).

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
tests/               # tests of the APM package in apm/: unit tests and sandboxed evals (see tests/README.md)
```

## APM package (deliverable)

The shareable package lives in [`apm/`](apm/README.md), a git submodule of https://github.com/luizvnasc/ai-hackathon-apm (clone with `git clone --recurse-submodules`, or run `git submodule update --init` in an existing clone). Teams install it with `apm install luizvnasc/ai-hackathon-apm`. The skills call the GitLab and Plane APIs directly, with credentials from the environment or `.env`: see [Configuration in the package README](apm/README.md).
