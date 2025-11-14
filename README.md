# sesapi-prod-argo-applications
ssh -i /home/cristiano/.ssh/sesapi -o IdentitiesOnly=yes" git push origin main

Forma mais rápida (Port Forward):
  kubectl port-forward svc/argocd-server -n argocd 8080:443
  Depois acesse: https://localhost:8080

  Credenciais:
  - Usuário: admin
  - Senha: HijP1WE5pgXY6MnN

## Gestão de Segredos

Os manifests não trazem mais senhas em texto plano. Antes de sincronizar cada aplicação no ArgoCD crie os Secrets necessários diretamente no cluster:

- `redis-credentials`: deve conter a chave `REDIS_URL` com a connection string Redis usada pelos serviços Rails (`cuidar-*`). Exemplo:
  ```bash
  kubectl create secret generic redis-credentials \
    --from-literal=REDIS_URL='rediss://:<senha>@cuidar.redis.cache.windows.net:6380?ssl=True' \
    -n <namespace-do-app>
  ```
- `azure-storage-credentials`: precisa das chaves `account-name` e `account-key` para o Kafka Connect.
  ```bash
  kubectl create secret generic azure-storage-credentials \
    --from-literal=account-name=<storage-account> \
    --from-literal=account-key=<storage-key> \
    -n saude-kafka-bigdata
  ```

Guarde os valores originais em um cofre (Azure Key Vault, 1Password, etc.) e somente replique no cluster. Dessa forma o histórico Git permanece limpo e compatível com o Push Protection do GitHub.
