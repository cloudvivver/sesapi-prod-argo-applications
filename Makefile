.PHONY: help port-forward pf logs logs-web logs-sidekiq pods status restart-web restart-sidekiq exec-web exec-sidekiq

# Variáveis
NAMESPACE := saude-homolog
PORT_LOCAL := 3030
PORT_REMOTE := 3000

help: ## Mostra esta mensagem de ajuda
	@echo "Comandos disponíveis:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

port-forward: ## Cria port-forward para a aplicação web (porta 3030)
	@echo "Conectando em http://localhost:$(PORT_LOCAL)"
	kubectl port-forward -n $(NAMESPACE) deployment/webhomolog $(PORT_LOCAL):$(PORT_REMOTE)

pf: port-forward ## Atalho para port-forward

logs: ## Mostra logs da aplicação web
	kubectl logs -n $(NAMESPACE) deployment/webhomolog -f --tail=100

logs-web: logs ## Atalho para logs da web

logs-sidekiq: ## Mostra logs do Sidekiq
	kubectl logs -n $(NAMESPACE) deployment/sidekiq -f --tail=100

pods: ## Lista todos os pods do namespace
	kubectl get pods -n $(NAMESPACE)

status: ## Mostra status da aplicação no ArgoCD
	@echo "=== ArgoCD Application ==="
	kubectl get application saude-homolog -n argocd
	@echo ""
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(NAMESPACE)
	@echo ""
	@echo "=== Ingress ==="
	kubectl get ingress -n $(NAMESPACE)

restart-web: ## Reinicia o deployment web
	kubectl rollout restart deployment/webhomolog -n $(NAMESPACE)

restart-sidekiq: ## Reinicia o deployment sidekiq
	kubectl rollout restart deployment/sidekiq -n $(NAMESPACE)

exec-web: ## Abre shell no pod web
	kubectl exec -it -n $(NAMESPACE) deployment/webhomolog -- /bin/bash

exec-sidekiq: ## Abre shell no pod sidekiq
	kubectl exec -it -n $(NAMESPACE) deployment/sidekiq -- /bin/bash

apply: ## Aplica todos os manifestos do saude-homolog
	kubectl apply -f saude-homolog/

sync: ## Força sync do ArgoCD
	kubectl patch application saude-homolog -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
	@echo "Sync iniciado. Use 'make status' para ver o progresso."

git-push: ## Faz commit e push das mudanças
	@echo "Fazendo commit das mudanças..."
	git add .
	@read -p "Mensagem do commit: " msg; \
	git commit -m "$$msg"
	GIT_SSH_COMMAND='ssh -i /home/cristiano/.ssh/cloudvivver -o IdentitiesOnly=yes' git push origin main
