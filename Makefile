SHELL := /bin/bash

NAMESPACE ?= wizapp
APP_LABEL ?= app=wizapp

# Mongo checks are optional — set these in your shell if you want Makefile-driven checks:
# export MONGO_HOST=10.0.1.23
# export MONGO_PORT=27017
# export MONGO_ADMIN_USER=...
# export MONGO_ADMIN_PASS=...
# export MONGO_APP_USER=...
# export MONGO_APP_PASS=...
# export MONGO_APP_DB=...
MONGO_PORT ?= 27017

.PHONY: help infra-init infra-plan infra-apply infra-destroy kubeconfig app-build-push app-deploy app-status \
        k8s-overview k8s-events k8s-logs k8s-shell k8s-verify-file k8s-verify-all \
        mongo-show mongo-ping-admin mongo-ping-app

help:
	@echo "Targets:"
	@echo "  infra-init        - terraform init"
	@echo "  infra-plan        - terraform plan"
	@echo "  infra-apply       - terraform apply"
	@echo "  infra-destroy     - terraform destroy"
	@echo "  kubeconfig        - configure kubectl for the created EKS cluster"
	@echo "  app-build-push    - build app image (with wizexercise.txt) and push to ECR"
	@echo "  app-deploy        - deploy Kubernetes manifests (namespace/secret/rbac/deploy/ingress)"
	@echo "  app-status        - show pods/services/ingress"
	@echo ""
	@echo "Troubleshooting / verification:"
	@echo "  k8s-overview      - show key K8s resources in $(NAMESPACE)"
	@echo "  k8s-events        - show recent events in $(NAMESPACE)"
	@echo "  k8s-logs          - tail logs for the wizapp deployment"
	@echo "  k8s-shell         - exec into the newest wizapp pod"
	@echo "  k8s-verify-file   - verify /app/wizexercise.txt exists and contains your name"
	@echo "  k8s-verify-all    - run overview + file verification"
	@echo ""
	@echo "Mongo optional checks (requires env vars like MONGO_HOST + creds and mongosh installed):"
	@echo "  mongo-show        - print Mongo connection settings detected from env"
	@echo "  mongo-ping-admin  - ping Mongo admin DB with admin creds"
	@echo "  mongo-ping-app    - ping app DB with app creds"

infra-init:
	cd infra/terraform && terraform init

infra-plan:
	cd infra/terraform && terraform plan

infra-apply:
	cd infra/terraform && terraform apply -auto-approve -var-file="terraform.tfvars"

infra-destroy:
	cd infra/terraform && terraform destroy -auto-approve

kubeconfig:
	cd infra/terraform && bash ../../scripts/kubeconfig.sh

app-build-push:
	bash scripts/build_and_push.sh

app-deploy:
	bash scripts/k8s_deploy.sh

app-status:
	kubectl -n $(NAMESPACE) get pods,svc,ingress -o wide

# -----------------------------
# Kubernetes troubleshooting
# -----------------------------

k8s-overview:
	@echo "== Context =="
	@kubectl config current-context || true
	@echo ""
	@echo "== Namespace: $(NAMESPACE) =="
	@kubectl get ns | grep -E "^$(NAMESPACE)\b" || true
	@echo ""
	@echo "== Nodes =="
	@kubectl get nodes -o wide
	@echo ""
	@echo "== Workloads & Services =="
	@kubectl -n $(NAMESPACE) get deploy,rs,pods,svc,ingress -o wide

k8s-events:
	@kubectl -n $(NAMESPACE) get events --sort-by=.metadata.creationTimestamp | tail -n 40

k8s-logs:
	@kubectl -n $(NAMESPACE) logs -f deploy/wizapp

k8s-shell:
	@POD="$$(kubectl -n $(NAMESPACE) get pods -l $(APP_LABEL) --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"; \
	echo "Exec into: $$POD"; \
	kubectl -n $(NAMESPACE) exec -it "$$POD" -- sh

k8s-verify-file:
	@POD="$$(kubectl -n $(NAMESPACE) get pods -l $(APP_LABEL) --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')"; \
	echo "Verifying wizexercise.txt in: $$POD"; \
	kubectl -n $(NAMESPACE) exec "$$POD" -- sh -lc 'ls -l /app/wizexercise.txt && echo "-----" && cat /app/wizexercise.txt'; \
	kubectl -n $(NAMESPACE) exec "$$POD" -- sh -lc 'test -f /app/wizexercise.txt && grep -q "Richard Barrett" /app/wizexercise.txt && echo "OK: wizexercise.txt present and correct"'

k8s-verify-all: k8s-overview k8s-verify-file
	@echo "All Kubernetes checks completed."

# -----------------------------
# Mongo optional checks (requires mongosh installed locally)
# -----------------------------

mongo-show:
	@echo "MONGO_HOST=$${MONGO_HOST:-<not set>}"
	@echo "MONGO_PORT=$(MONGO_PORT)"
	@echo "MONGO_ADMIN_USER=$${MONGO_ADMIN_USER:-<not set>}"
	@echo "MONGO_APP_USER=$${MONGO_APP_USER:-<not set>}"
	@echo "MONGO_APP_DB=$${MONGO_APP_DB:-<not set>}"

mongo-ping-admin:
	@test -n "$${MONGO_HOST:-}" || (echo "MONGO_HOST not set"; exit 1)
	@test -n "$${MONGO_ADMIN_USER:-}" || (echo "MONGO_ADMIN_USER not set"; exit 1)
	@test -n "$${MONGO_ADMIN_PASS:-}" || (echo "MONGO_ADMIN_PASS not set"; exit 1)
	mongosh "mongodb://$${MONGO_ADMIN_USER}:$${MONGO_ADMIN_PASS}@$${MONGO_HOST}:$(MONGO_PORT)/admin" --eval 'db.runCommand({ ping: 1 })'

mongo-ping-app:
	@test -n "$${MONGO_HOST:-}" || (echo "MONGO_HOST not set"; exit 1)
	@test -n "$${MONGO_APP_USER:-}" || (echo "MONGO_APP_USER not set"; exit 1)
	@test -n "$${MONGO_APP_PASS:-}" || (echo "MONGO_APP_PASS not set"; exit 1)
	@test -n "$${MONGO_APP_DB:-}" || (echo "MONGO_APP_DB not set"; exit 1)
	mongosh "mongodb://$${MONGO_APP_USER}:$${MONGO_APP_PASS}@$${MONGO_HOST}:$(MONGO_PORT)/$${MONGO_APP_DB}?authSource=$${MONGO_APP_DB}" --eval 'db.runCommand({ ping: 1 })'
