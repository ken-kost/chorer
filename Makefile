.PHONY: \
		dev \
		test \
		compile \
		compile-assets \
		check-compile \
		check-release \
		check-migrations \
		check-ci \
		reset-db \
		seed-db \
		demo-db \
		load-config-envs \

		devstack \
		devstack-build \
		devstack-clean \
		devstack-shell \
		devstack-run \

		prodstack \
		prodstack-build \

		heroku/login \
		heroku/build-web \
		heroku/build-release \
		heroku/push-web \
		heroku/push-release  \
		heroku/build-and-push \
		heroku/release \
		heroku/manual-deploy \
		heroku/confirm-manual-deploy \
		capture-backup \
		latest.dump \
		import-latest-db  \
		set-remotes

DEFAULT_GOAL: help

DEVELOPMENT?=https://git.heroku.com/brevity-develop.git
STAGING?=https://git.heroku.com/brevity-stage.git
PRODUCTION?=https://git.heroku.com/brevity-prod.git
PGDATABASE?=brevity_dev

APP_NAME?=brevity
HEROKU_REGISTRY=registry.heroku.com

export LOCAL_USER_ID ?= $(shell id -u $$USER)
export DOCKER_BUILDKIT=1

# -------------------
# --- DEFINITIONS ---
# -------------------

require-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "ERROR: Environment variable not set: \"$*\""; \
		exit 1; \
	fi

# -----------------
# --- APP TASKS ---
# -----------------

dev:
	mix ecto.reset && iex -S mix phx.server

test:
	mix test

compile:
	@mix do deps.get, compile --warnings-as-errors

compile-assets:
	cd assets && \
  yarn install && \
  yarn deploy && \
  cd ../ && \
  mix phx.digest

check-compile: compile
	@MIX_ENV=test mix compile --warnings-as-errors
	@mix format --check-formatted
	@mix surface.format --check-formatted
	@mix credo list

check-migrations:
	@MIX_ENV=test mix ecto.reset
	@MIX_ENV=test mix ecto.rollback --all
	@MIX_ENV=test mix ecto.migrate

check-release:
	@MIX_ENV=test mix release --overwrite

check-ci: check-compile test check-release check-migrations

reset-db:
	mix ecto.reset

seed-db: reset-db
		mix elasticsearch.build products --cluster Brevity.Tools.Elasticsearch.Cluster && \
		mix ecto.seed

demo-db: reset-db
		mix ecto.load.demo

## Exports dev configuration from /lib/brevity_config.ex as env variables
load-config-envs:
	@mix run -e "IO.puts(BanmedConfig.template())" | egrep "#.*=" | sed "s/# //"

capture-backup: require-REMOTE
	heroku pg:backups:capture --remote ${REMOTE}

latest.dump: require-REMOTE
	heroku pg:backups:download --remote ${REMOTE}

import-latest-db: require-PGDATABASE latest.dump
	dropdb --if-exists ${PGDATABASE} && \
	createdb ${PGDATABASE} && \
	pg_restore --verbose --clean --no-acl --no-owner --dbname=${PGDATABASE} latest.dump

set-remotes: require-DEVELOPMENT require-STAGING require-PRODUCTION
	@git remote rm development || true
	@git remote rm staging || true
	@git remote rm production || true
	git remote add development ${DEVELOPMENT}
	git remote add staging ${STAGING}
	git remote add production ${PRODUCTION}


# -----------------------
# --- DOCKER DEVSTACK ---
# -----------------------

## Builds the development Docker image
devstack-build:
	@docker build \
		--target build \
		--ssh default .\
		--build-arg MIX_ENV=dev \
		--build-arg APP_NAME=brevity \
		--tag brevity:latest

## Stops all development containers
devstack-clean:
	@docker-compose down -v

## Starts all development containers in the foreground
devstack: devstack-build
	@docker-compose up

## Spawns an interactive Bash shell in development web container
devstack-shell:
	@docker exec -e COLUMNS="`tput cols`" -e LINES="`tput lines`" -u ${LOCAL_USER_ID} -it $$(docker-compose ps -q web) /bin/bash -c "reset -w && /bin/bash"

## Starts the development server inside docker
devstack-run: devstack-build
	@docker-compose up -d &&\
		docker-compose exec web mix deps.get && \
		docker-compose exec web mix ecto.setup && \
		docker-compose exec web iex -S mix phx.server

## Builds the production Docker image
prodstack-build:
	@docker build \
		--target release \
		--ssh default .\
		--build-arg MIX_ENV=prod \
		--build-arg APP_NAME=brevity \
		--tag brevity:release

## Starts all production containers in the foreground
prodstack: prodstack-build
	@docker-compose -f docker-compose-prod.yml up

# -------------------------------
# --- DOCKER HEROKU PRODSTACK ---
# -------------------------------

## Logs in to heroku container registry
heroku/login: require-HEROKU_API_KEY require-HEROKU_REGISTRY
	@docker login --username=_ --password=$(HEROKU_API_KEY) $(HEROKU_REGISTRY)

## Builds the production Docker web image
heroku/build-web: require-APP_NAME require-HEROKU_REGISTRY require-HEROKU_APP_NAME
	@docker build --ssh default .\
		--target release \
		--build-arg MIX_ENV=prod \
		--build-arg APP_NAME=${APP_NAME} \
		--tag ${HEROKU_REGISTRY}/${HEROKU_APP_NAME}/web

## Builds the production Docker release phase image
heroku/build-release: require-HEROKU_REGISTRY require-HEROKU_APP_NAME
	@docker build --ssh default .\
		--target release-phase \
		--build-arg MIX_ENV=prod \
		--build-arg APP_NAME=${APP_NAME} \
		--tag ${HEROKU_REGISTRY}/${HEROKU_APP_NAME}/release

## Push heroku web image to container registry
heroku/push-web: require-HEROKU_APP_NAME require-HEROKU_REGISTRY
	@docker push ${HEROKU_REGISTRY}/${HEROKU_APP_NAME}/web

## Push heroku release phase image to container registry
heroku/push-release: require-HEROKU_APP_NAME require-HEROKU_REGISTRY
	@docker push ${HEROKU_REGISTRY}/${HEROKU_APP_NAME}/release

## Builds production images and pushes them to heroku container registry
heroku/build-and-push: heroku/login heroku/build-web heroku/build-release heroku/push-web heroku/push-release

## Creates a new release on heroku
heroku/release: require-HEROKU_APP_NAME require-HEROKU_API_KEY
	@HEROKU_API_KEY=$(HEROKU_API_KEY) heroku container:release web release -a $(HEROKU_APP_NAME)

## Deploys the local version to heroku
heroku/manual-deploy: HEROKU_API_KEY?=`heroku auth:token`
heroku/manual-deploy: require-HEROKU_APP_NAME heroku/confirm-manual-deploy heroku/build-and-push heroku/release

heroku/confirm-manual-deploy:
	@printf "This will deploy your local working copy to $(HEROKU_APP_NAME). Contibrevity [y/N]? " && read ans && [ $${ans:-N} = y ]


# ------------
# --- HELP ---
# ------------

## Shows the help menu
help:
	@echo "Please use \`make <target>' where <target> is one of\n\n"
	@awk '/^[a-zA-Z\-\_\/0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = substr($$1, 0, index($$1, ":")); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			printf "%-30s %s\n", helpCommand, helpMessage; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)