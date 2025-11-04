COMPOSE_FILE=docker-compose.yaml

# Стандартные цели
.PHONY: up down build restart recreate rebuild

up:
	docker compose -f $(COMPOSE_FILE) up -d

build:
	docker compose -f $(COMPOSE_FILE) --build

down:
	docker compose -f $(COMPOSE_FILE) down

restart:
	docker compose -f $(COMPOSE_FILE) restart

recreate:
	docker compose -f $(COMPOSE_FILE) down && docker compose -f $(COMPOSE_FILE) up -d

rebuild:
	docker compose -f $(COMPOSE_FILE) build && docker compose -f $(COMPOSE_FILE) down && docker compose -f $(COMPOSE_FILE) up -d
