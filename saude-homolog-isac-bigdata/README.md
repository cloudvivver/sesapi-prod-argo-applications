# Debezium CDC para PostgreSQL - ISAC

Este projeto implementa Change Data Capture (CDC) usando Debezium para capturar alterações em tempo real das tabelas do PostgreSQL do tenant ISAC e enviá-las para o Kafka.

## Estrutura do Projeto

```
saude-homolog-isac-bigdata/
├── postgres-credentials-secret.yaml        # Credenciais PostgreSQL
├── kafka-connect-debezium.yaml            # Kafka Connect com Debezium
├── config/
    ├── debezium-postgres-cdc-connector.json # Configuração CDC
    └── debezium-api.sh                     # Script de gerenciamento
└── ... (outros arquivos da aplicação)
```

## Configuração Específica ISAC

- **Database**: `saude_homolog_tenant_isac_db`
- **Server Name**: `isac` (prefixo dos tópicos)
- **Porta API**: `30085`
- **Slot**: `debezium_slot_isac`
- **Publication**: `debezium_publication_isac`

## Tabelas Monitoradas

### Schema `seguranca`:
- `operador` - Dados de operadores/usuários
- `perfil` - Perfis de acesso

### Schema `public`:
- `operadorsetor` - Relacionamento operador-setor
- `municipio` - Dados de municípios
- `unidadesaude` - Unidades de saúde
- `setor` - Setores
- `profissional` - Dados de profissionais
- `especialidade` - Especialidades médicas
- `profissionalespec` - Relacionamento profissional-especialidade
- `unidadeprofisespec` - Relacionamento unidade-profissional-especialidade

## Deploy

1. Aplicar os manifests:
```bash
kubectl apply -f postgres-credentials-secret.yaml
kubectl apply -f kafka-connect-debezium.yaml
```

2. Aguardar o pod ficar pronto:
```bash
kubectl get pods -l app=kafka-connect-debezium-isac -w
```

3. Criar o conector CDC:
```bash
cd config/
./debezium-api.sh create
```

## Monitoramento

- **Debezium Connect API**: http://localhost:30085
- **Kafka UI**: http://localhost:30080 (no namespace saude-kafka-bigdata)

## Gerenciamento do CDC

```bash
# Criar conector
./debezium-api.sh create

# Listar conectores
./debezium-api.sh list

# Status do conector
./debezium-api.sh status

# Ver tópicos esperados
./debezium-api.sh topics

# Reiniciar conector
./debezium-api.sh restart

# Deletar conector
./debezium-api.sh delete
```

## Tópicos Kafka Gerados

Cada tabela gera um tópico no formato `isac.<schema>.<tabela>`:

- `isac.seguranca.operador`
- `isac.seguranca.perfil`
- `isac.public.operadorsetor`
- `isac.public.municipio`
- `isac.public.unidadesaude`
- `isac.public.setor`
- `isac.public.profissional`
- `isac.public.especialidade`
- `isac.public.profissionalespec`
- `isac.public.unidadeprofisespec`
- `__debezium-heartbeat.isac` (heartbeat)

## Configuração PostgreSQL

Para que o CDC funcione, configure no PostgreSQL:

```sql
-- Habilitar replicação lógica
ALTER SYSTEM SET wal_level = 'logical';

-- Criar usuário para replicação (se necessário)
CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'senha123';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA seguranca TO replicator;

-- Criar publication (será criado automaticamente pelo Debezium)
-- CREATE PUBLICATION debezium_publication_isac FOR TABLE 
--   seguranca.operador, seguranca.perfil,
--   public.operadorsetor, public.municipio, public.unidadesaude,
--   public.setor, public.profissional, public.especialidade,
--   public.profissionalespec, public.unidadeprofisespec;
```

Adicione no `pg_hba.conf`:
```
host replication replicator 0.0.0.0/0 md5
```

## Estrutura dos Eventos

Cada evento CDC contém:
```json
{
  "op": "c|u|d|r",  // create, update, delete, read
  "ts_ms": 1725103384000,
  "source": {
    "version": "2.4.2.Final",
    "connector": "postgresql",
    "name": "isac",
    "ts_ms": 1725103384000,
    "snapshot": "false",
    "db": "saude_homolog_tenant_isac_db",
    "schema": "public",
    "table": "operador"
  },
  "after": { /* dados da linha após a mudança */ },
  "before": { /* dados da linha antes da mudança (só em updates/deletes) */ }
}
```

## Diferenças dos Outros Tenants

- **Porta API**: 30085 (vs 30084 do homolog)
- **Database**: `saude_homolog_tenant_isac_db`
- **Tópicos**: Prefixo `isac.*`
- **Group ID**: `debezium-cluster-isac`