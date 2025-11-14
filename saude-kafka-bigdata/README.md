# Kafka Connect com Azure Blob Storage

Este projeto implementa Kafka Connect para persistir eventos do Kafka em arquivos Parquet no Azure Blob Storage com particionamento por data.

## Estrutura do Projeto

```
saude-kafka-bigdata/
├── kafka-connect.yaml             # Deployment Kafka Connect  
├── kafka.yaml                     # Kafka broker
├── kafdrop.yaml                   # UI Kafdrop
├── kafka-ui.yaml                  # UI Kafka
├── zookeeper.yaml                 # ZooKeeper
└── config/
    ├── azure-blob-sink-connector.json  # Config do conector
    └── kafka-connect-api.sh            # Script de gerenciamento
```

## Deploy

1. Criar o Secret com as credenciais do Azure Storage (um por namespace):
```bash
kubectl create secret generic azure-storage-credentials \\
  --from-literal=account-name=<storage-account> \\
  --from-literal=account-key=<storage-key> \\
  -n saude-kafka-bigdata
```
> Substitua `<storage-account>` e `<storage-key>` pelos valores reais e garanta que o Secret seja criado antes de sincronizar o aplicativo no ArgoCD.

2. Aplicar os manifests via ArgoCD ou kubectl:
```bash
kubectl apply -f zookeeper.yaml
kubectl apply -f kafka.yaml
kubectl apply -f kafka-connect.yaml
kubectl apply -f kafdrop.yaml
kubectl apply -f kafka-ui.yaml
```

3. Aguardar os pods ficarem prontos:
```bash
kubectl get pods -w
```

4. Criar o conector Azure Blob:
```bash
cd config/
./kafka-connect-api.sh create
```

## Monitoramento

- **Kafka UI**: http://localhost:30080
- **Kafdrop**: http://localhost:30090  
- **Kafka Connect API**: http://localhost:30083

## Gerenciamento do Conector

```bash
# Listar conectores
./kafka-connect-api.sh list

# Status do conector
./kafka-connect-api.sh status azure-parquet-sink

# Reiniciar conector
./kafka-connect-api.sh restart azure-parquet-sink

# Deletar conector
./kafka-connect-api.sh delete azure-parquet-sink
```

## Estrutura de Dados no Azure Blob

Os dados são armazenados no formato:
```
/formulario_acessos_raw/ano=YYYY/mes=MM/dia=dd/hora=HH/arquivo-xxx.parquet
```

## Configuração

- **Tópico**: `eventos-rails`
- **Container**: `formulario-acessos-raw`
- **Formato**: Parquet
- **Particionamento**: Por hora (1h)
- **Timezone**: America/Sao_Paulo
- **Credenciais**: os parâmetros `azure.blob.storage.account.name` e `azure.blob.storage.account.key` utilizam as variáveis de ambiente expostas pelo Secret `azure-storage-credentials`.
