COMPOSE := docker compose -f infra/compose.yml --env-file infra/.env
# Entry-point service of each tool (compose starts its dependencies too)
JIRA   := jira
GITLAB := gitlab
PLANE  := proxy

.PHONY: help setup up down stop ps logs status jira gitlab plane gitlab-password nuke gitlab-seed

help: ## List commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup: ## Create infra/.env with random secrets (never overwrites an existing one)
	@if [ -f infra/.env ]; then echo "infra/.env already exists — nothing to do"; exit 0; fi; \
	cp infra/.env.example infra/.env; \
	sed -i "s|^GITLAB_ROOT_PASSWORD=.*|GITLAB_ROOT_PASSWORD=Hack-$$(openssl rand -hex 8)|" infra/.env; \
	sed -i "s|^SECRET_KEY=.*|SECRET_KEY=$$(openssl rand -hex 32)|" infra/.env; \
	sed -i "s|^LIVE_SERVER_SECRET_KEY=.*|LIVE_SERVER_SECRET_KEY=$$(openssl rand -hex 32)|" infra/.env; \
	sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$$(openssl rand -hex 16)|" infra/.env; \
	echo "infra/.env created"

up: setup ## Start Jira + GitLab + Plane
	$(COMPOSE) up -d

jira: setup ## Start Jira only
	$(COMPOSE) up -d $(JIRA)

gitlab: setup ## Start GitLab only
	$(COMPOSE) up -d $(GITLAB)

plane: setup ## Start Plane only
	$(COMPOSE) up -d $(PLANE)

stop: ## Stop containers (keeps data)
	$(COMPOSE) stop

down: ## Remove containers (keeps volumes/data)
	$(COMPOSE) down

ps: ## Container status
	$(COMPOSE) ps

logs: ## Logs (e.g. make logs s=gitlab)
	$(COMPOSE) logs -f --tail=200 $(s)

status: ## Check that the 3 UIs respond
	@. infra/.env; \
	for u in "Jira|http://localhost:$$JIRA_PORT/status" "GitLab|http://localhost:$$GITLAB_HTTP_PORT/users/sign_in" "Plane|http://localhost:$$PLANE_PORT/"; do \
	  n=$${u%%|*}; url=$${u#*|}; \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $$url); \
	  printf "  %-7s %-45s HTTP %s\n" $$n $$url $$code; \
	done

gitlab-password: ## Print the GitLab root password
	@grep ^GITLAB_ROOT_PASSWORD infra/.env | cut -d= -f2

gitlab-seed: ## Seed the demo acme/inventory-manager project (RESET=1 recreates it)
	docker cp infra/gitlab/seed/inventory_manager.rb $(GITLAB):/tmp/inventory_manager.rb
	docker exec -e RESET=$(RESET) $(GITLAB) gitlab-rails runner /tmp/inventory_manager.rb

nuke: ## DELETE containers AND volumes (all data!)
	@read -p "This deletes ALL Jira/GitLab/Plane data. Confirm? [y/N] " a; [ "$$a" = y ] && $(COMPOSE) down -v
