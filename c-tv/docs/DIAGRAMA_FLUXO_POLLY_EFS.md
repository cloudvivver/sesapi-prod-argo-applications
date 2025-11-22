# Diagrama de Fluxo: C-TV com AWS Polly e EFS

## Arquitetura Completa - Ciclo de Vida do Processamento de Áudio

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                  USUÁRIO FINAL                                   │
│                          (Requisição: texto → áudio)                             │
└────────────────────────────────┬────────────────────────────────────────────────┘
                                 │
                                 │ HTTP Request
                                 │ POST /speak?texto=X&voz=Camila
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            INGRESS / LOAD BALANCER                               │
│                         (ingress-nginx / ALB)                                    │
└────────────────────────────────┬────────────────────────────────────────────────┘
                                 │
                                 │ Roteamento (Round-Robin / Least Connections)
                                 │
     ┌───────────────────────────┼───────────────────────────┐
     │                           │                           │
     ▼                           ▼                           ▼
┏━━━━━━━━━━━━━━━━━┓   ┏━━━━━━━━━━━━━━━━━┓   ┏━━━━━━━━━━━━━━━━━┓
┃   POD C-TV #1   ┃   ┃   POD C-TV #2   ┃   ┃   POD C-TV #3   ┃
┃ (Node: node-01) ┃   ┃ (Node: node-02) ┃   ┃ (Node: node-03) ┃
┗━━━━━━━━━━━━━━━━━┛   ┗━━━━━━━━━━━━━━━━━┛   ┗━━━━━━━━━━━━━━━━━┛
     │                           │                           │
     └───────────────────────────┼───────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │ Qualquer pod pode       │
                    │ processar a requisição  │
                    └────────────┬────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          PROCESSAMENTO NO POD C-TV                               │
│                                                                                  │
│  1. Receber requisição (texto, voz, parâmetros)                                 │
│  2. Gerar chave de cache: MD5(texto + voz)                                      │
│     Exemplo: a3f5b8c2d9e4f1a6b7c8d9e0f1a2b3c4                                   │
│  3. Verificar se arquivo existe no EFS                                          │
└────────────────────────────────┬────────────────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
        Cache HIT ✅                      Cache MISS ❌
                    │                         │
                    ▼                         ▼
    ┌────────────────────────┐   ┌────────────────────────────────┐
    │   CENÁRIO 1: HIT       │   │   CENÁRIO 2: MISS              │
    │   (Áudio já existe)    │   │   (Primeira vez)               │
    └────────────────────────┘   └────────────────────────────────┘
                    │                         │
                    │                         │
                    ▼                         ▼


════════════════════════════════════════════════════════════════════════════════
                            CENÁRIO 1: CACHE HIT ✅
════════════════════════════════════════════════════════════════════════════════

POD C-TV
   │
   │ 1. Buscar arquivo no EFS
   ▼
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                          AMAZON EFS (FileSystem)                              ┃
┃                         fs-XXXXXXXX (c-tv-audio-cache)                        ┃
┃                                                                               ┃
┃  Mount Point: /app/audio_cache                                                ┃
┃  Modo: ReadWriteMany (RWX)                                                    ┃
┃                                                                               ┃
┃  /app/audio_cache/                                                            ┃
┃  ├── a3f5b8c2d9e4f1a6b7c8d9e0f1a2b3c4.mp3  ✅ ENCONTRADO!                    ┃
┃  ├── f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6.mp3                                    ┃
┃  ├── 9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4.mp3                                     ┃
┃  └── ...                                                                      ┃
┃                                                                               ┃
┃  Características:                                                             ┃
┃  • Compartilhado entre TODOS os pods                                          ┃
┃  • Persistente (dados não se perdem em restart)                               ┃
┃  • Elástico (cresce automaticamente)                                          ┃
┃  • Lifecycle: Infrequent Access após 30 dias (economia ~85%)                 ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
   │
   │ 2. Ler arquivo .mp3 do EFS
   ▼
POD C-TV
   │
   │ 3. Retornar áudio ao usuário
   ▼
USUÁRIO FINAL
   │
   └─► ✅ Áudio entregue (latência ~20-50ms)
       💰 Custo: $0 (sem chamada ao Polly)
       ⚡ Performance: EXCELENTE



════════════════════════════════════════════════════════════════════════════════
                            CENÁRIO 2: CACHE MISS ❌
════════════════════════════════════════════════════════════════════════════════

POD C-TV
   │
   │ 1. Arquivo NÃO existe no EFS
   │ 2. Preparar requisição TTS
   ▼
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                    AWS POLLY (Text-to-Speech Service)                         ┃
┃                              Região: sa-east-1                                ┃
┃                                                                               ┃
┃  Requisição:                                                                  ┃
┃  {                                                                            ┃
┃    "Text": "Olá, bem-vindo ao sistema",                                      ┃
┃    "VoiceId": "Camila",                                                       ┃
┃    "OutputFormat": "mp3",                                                     ┃
┃    "Engine": "standard"                                                       ┃
┃  }                                                                            ┃
┃                                                                               ┃
┃  ┌──────────────────────────────────────┐                                    ┃
┃  │  1. Validar credenciais (IRSA)       │                                    ┃
┃  │  2. Processar texto                  │                                    ┃
┃  │  3. Sintetizar voz (Neural/Standard) │                                    ┃
┃  │  4. Gerar arquivo MP3                │                                    ┃
┃  └──────────────────────────────────────┘                                    ┃
┃                                                                               ┃
┃  Vozes Disponíveis (pt-BR):                                                   ┃
┃  • Camila (Standard) - Feminina                                               ┃
┃  • Vitoria (Standard) - Feminina                                              ┃
┃  • Ricardo (Standard) - Masculina                                             ┃
┃                                                                               ┃
┃  💰 Custo: ~$4 por 1 milhão de caracteres (Standard)                         ┃
┃  ⏱️  Latência: 1-2 segundos                                                  ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
   │
   │ 3. Resposta: arquivo .mp3 (bytes)
   ▼
POD C-TV
   │
   │ 4. Salvar no EFS para cache futuro
   ▼
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                          AMAZON EFS (FileSystem)                              ┃
┃                         fs-XXXXXXXX (c-tv-audio-cache)                        ┃
┃                                                                               ┃
┃  /app/audio_cache/                                                            ┃
┃  ├── a3f5b8c2d9e4f1a6b7c8d9e0f1a2b3c4.mp3  ✅ SALVO AGORA!                   ┃
┃  ├── f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6.mp3                                    ┃
┃  └── ...                                                                      ┃
┃                                                                               ┃
┃  Próximas requisições: CACHE HIT! ✅                                          ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
   │
   │ 5. Retornar áudio ao usuário
   ▼
USUÁRIO FINAL
   │
   └─► ✅ Áudio entregue (latência ~1-2s primeira vez)
       💰 Custo: $4/1M caracteres (apenas primeira vez)
       ⚡ Performance: BOA (próximas requisições serão EXCELENTES)


════════════════════════════════════════════════════════════════════════════════
```

## Componentes da Arquitetura

### 1. **Cluster EKS (prod-viver)**
- **Namespace**: `c-tv`
- **Deployment**: 3 réplicas do C-TV
- **Nodes**: Distribuídos em múltiplas AZs (sa-east-1a, sa-east-1b, sa-east-1c)
- **Service**: LoadBalancer / ClusterIP com Ingress

### 2. **Pods C-TV**
- **Imagem**: `c-tv:polly` (AWS Polly como provider padrão)
- **Recursos**:
  - CPU: 500m-1000m
  - Memory: 512Mi-1Gi
- **Volumes Montados**:
  - `/app/audio_cache` → PVC montando EFS (RWX)
- **ServiceAccount**: `c-tv-polly` (IRSA habilitado para AWS Polly)

### 3. **Amazon EFS (Elastic File System)**
- **FileSystemId**: `fs-XXXXXXXX`
- **Nome**: `c-tv-audio-cache`
- **Performance Mode**: General Purpose
- **Throughput Mode**: Elastic
- **Encryption**: Habilitada (at-rest)
- **Lifecycle Policy**: Infrequent Access após 30 dias (~85% economia)
- **Acesso**: ReadWriteMany (RWX) - **TODOS os pods montam o mesmo filesystem**
- **Capacidade**: Elástica (inicia ~10GB, cresce automaticamente)

### 4. **AWS Polly**
- **Região**: sa-east-1 (São Paulo)
- **Engine**: Standard (padrão, custo-efetivo)
- **Vozes pt-BR**: Camila, Vitoria, Ricardo
- **Autenticação**: IRSA (IAM Role for Service Accounts)
- **Custo**: $4 por 1 milhão de caracteres (Standard)

### 5. **Segurança e Rede**

#### EFS Security Group (`c-tv-efs-sg`)
```
Inbound Rules:
┌──────────┬──────────┬────────────────────────────────┐
│ Protocol │ Port     │ Source                         │
├──────────┼──────────┼────────────────────────────────┤
│ TCP      │ 2049     │ EKS Node Security Group        │
│          │ (NFS)    │ (sg-XXXXXXXXXXXXXXXXX)         │
└──────────┴──────────┴────────────────────────────────┘
```

#### IAM Role (IRSA - AWS Polly)
```
Role: eksctl-prod-viver-addon-c-tv-polly-Role
Attached Policies:
  - CTVPollyReadOnlyPolicy
    Permissions:
      ✓ polly:SynthesizeSpeech
      ✓ polly:DescribeVoices
```

#### IAM Role (IRSA - EFS CSI Driver)
```
Role: EFS-CSI-Driver-Role-prod-viver
Attached Policies:
  - CTVEFSCSIDriverPolicy
    Permissions:
      ✓ elasticfilesystem:DescribeFileSystems
      ✓ elasticfilesystem:CreateAccessPoint
      ✓ elasticfilesystem:TagResource
      ✓ elasticfilesystem:DeleteAccessPoint
```

---

## Fluxo Detalhado Passo a Passo

### ✅ **Requisição com CACHE HIT** (Cenário Ideal)

| Passo | Componente | Ação | Latência | Custo |
|-------|-----------|------|----------|-------|
| 1 | Usuário | Envia requisição HTTP POST `/speak` | 0ms | - |
| 2 | Ingress | Roteia para um pod C-TV (qualquer) | ~5ms | - |
| 3 | Pod C-TV | Calcula hash MD5(texto+voz) | ~1ms | - |
| 4 | Pod C-TV | Verifica arquivo no EFS | ~5ms | - |
| 5 | EFS | Arquivo encontrado! `/app/audio_cache/hash.mp3` | ~5ms | $0 |
| 6 | Pod C-TV | Lê arquivo .mp3 do EFS | ~10ms | - |
| 7 | Pod C-TV | Retorna áudio via HTTP 200 | ~5ms | - |
| **TOTAL** | | **Cache HIT** | **~30ms** | **$0** |

**Benefícios**:
- ⚡ Latência ultra-baixa (~30ms)
- 💰 Custo zero (não chama AWS Polly)
- 🌍 Qualquer réplica pode servir o cache

---

### ❌ **Requisição com CACHE MISS** (Primeira Vez)

| Passo | Componente | Ação | Latência | Custo |
|-------|-----------|------|----------|-------|
| 1 | Usuário | Envia requisição HTTP POST `/speak` | 0ms | - |
| 2 | Ingress | Roteia para um pod C-TV (qualquer) | ~5ms | - |
| 3 | Pod C-TV | Calcula hash MD5(texto+voz) | ~1ms | - |
| 4 | Pod C-TV | Verifica arquivo no EFS | ~5ms | - |
| 5 | EFS | Arquivo NÃO encontrado! | ~5ms | $0 |
| 6 | Pod C-TV | Prepara requisição TTS para AWS Polly | ~2ms | - |
| 7 | **AWS Polly** | Sintetiza voz (Standard, Camila, pt-BR) | **1000-2000ms** | **$4/1M chars** |
| 8 | Pod C-TV | Recebe áudio .mp3 (bytes) | ~50ms | - |
| 9 | Pod C-TV | Salva arquivo no EFS: `/app/audio_cache/hash.mp3` | ~20ms | - |
| 10 | EFS | Arquivo persistido (disponível para todas as réplicas) | ~10ms | - |
| 11 | Pod C-TV | Retorna áudio via HTTP 200 | ~5ms | - |
| **TOTAL** | | **Cache MISS** | **~1100-2100ms** | **$4/1M chars** |

**Importante**:
- 🕐 Latência maior na primeira requisição (~1-2s)
- 💰 Custo apenas na primeira vez (reutilizado depois)
- ✅ Próximas requisições: **CACHE HIT** (~30ms, $0)

---

## Comparação: Com EFS vs Sem EFS (EBS)

### ❌ **Sem EFS (usando EBS por pod)**

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  POD #1     │  │  POD #2     │  │  POD #3     │
│             │  │             │  │             │
│  Cache EBS  │  │  Cache EBS  │  │  Cache EBS  │
│  (Volume 1) │  │  (Volume 2) │  │  (Volume 3) │
│             │  │             │  │             │
│  ❌ Isolado │  │  ❌ Isolado │  │  ❌ Isolado │
└─────────────┘  └─────────────┘  └─────────────┘

Problemas:
- Cada pod tem SEU PRÓPRIO cache (não compartilhado)
- Áudio gerado no Pod #1 NÃO é visível para Pod #2 ou #3
- Mesmo texto pode resultar em 3 chamadas ao Polly (uma por pod)
- Custo 3x maior
- Desperdício de armazenamento (dados duplicados)
- ReadWriteOnce (RWO) - volume preso a um único node
```

### ✅ **Com EFS (cache compartilhado)**

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  POD #1     │  │  POD #2     │  │  POD #3     │
│      │      │  │      │      │  │      │      │
│      └──────┼──┼──────┴──────┼──┼──────┘      │
│             │  │             │  │             │
└─────────────┘  └─────────────┘  └─────────────┘
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │
                    ┏━━━━▼━━━━┓
                    ┃   EFS   ┃
                    ┃  Cache  ┃
                    ┃ (RWX)   ┃
                    ┗━━━━━━━━━┛

Benefícios:
- ✅ Cache ÚNICO compartilhado entre TODOS os pods
- ✅ Áudio gerado por qualquer pod é visível para todos
- ✅ Mesmo texto resulta em apenas 1 chamada ao Polly
- ✅ Custo otimizado (reutilização máxima)
- ✅ ReadWriteMany (RWX) - múltiplos pods/nodes simultaneamente
- ✅ Persistente e elástico
```

---

## Estimativa de Custo e Economia

### Cenário Real: 100.000 requisições/mês

**Premissas**:
- Média de 50 caracteres por requisição
- Taxa de cache hit: 70% (após período de aquecimento)

#### ❌ Sem EFS (cache fragmentado por pod)
```
Total de caracteres sintetizados:
  100.000 req × 50 chars = 5.000.000 caracteres

Chamadas ao Polly (assumindo distribuição uniforme entre 3 pods):
  Cache hit por pod: ~33% (apenas cache local)
  Cache miss: ~67%

  Custo Polly: 5.000.000 × 0.67 × ($4 / 1.000.000) = $13.40

Custo EBS:
  3 volumes × $0.08/GB/mês × 10GB = $2.40

CUSTO TOTAL: $15.80/mês
```

#### ✅ Com EFS (cache compartilhado)
```
Total de caracteres sintetizados:
  100.000 req × 50 chars = 5.000.000 caracteres

Chamadas ao Polly (cache compartilhado entre todos os pods):
  Cache hit global: 70%
  Cache miss: 30%

  Custo Polly: 5.000.000 × 0.30 × ($4 / 1.000.000) = $6.00

Custo EFS:
  Standard: $0.30/GB/mês × 10GB = $3.00
  (Após 30 dias, 80% migra para IA: $0.30 × 2GB + $0.045 × 8GB = $0.96)

CUSTO TOTAL: $6.96/mês (após lifecycle)
```

#### 💰 **Economia: $8.84/mês (56% de redução)**

**Escalando para 1 milhão de requisições/mês:**
- Sem EFS: ~$158/mês
- Com EFS: ~$69/mês
- **Economia: $89/mês (56% de redução)**

---

## Métricas e Monitoramento

### CloudWatch Metrics (AWS Polly)

```yaml
Métricas Relevantes:
  - AWS/Polly/RequestCount: Número de chamadas ao Polly
  - AWS/Polly/ResponseTime: Latência da síntese
  - AWS/Polly/CharacterCount: Total de caracteres sintetizados

Alertas Recomendados:
  - RequestCount > 10.000/hora (possível problema de cache)
  - CharacterCount > 1.000.000/dia (monitorar custo)
```

### CloudWatch Metrics (Amazon EFS)

```yaml
Métricas Relevantes:
  - AWS/EFS/ClientConnections: Número de conexões ativas
  - AWS/EFS/DataReadIOBytes: Leitura de dados (cache hits)
  - AWS/EFS/DataWriteIOBytes: Escrita de dados (novos caches)
  - AWS/EFS/PercentIOLimit: Utilização de throughput
  - AWS/EFS/TotalIOBytes: Total de I/O

Alertas Recomendados:
  - PercentIOLimit > 80% (considerar aumentar throughput)
  - ClientConnections < 3 (verificar pods desconectados)
```

### Logs do C-TV (Pod)

```
Exemplos de Logs:

Cache HIT:
[TTSService] ✅ Cache HIT: Olá, bem-vindo ao sistema
[TTSService] Arquivo lido do EFS: /app/audio_cache/a3f5b8c2...mp3
[TTSService] Latência: 25ms

Cache MISS:
[TTSService] 🔄 Cache MISS: Gerando áudio para 'Olá, bem-vindo...'
[AWSPolly] Sintetizando 28 caracteres (voz: Camila)
[AWSPolly] Síntese concluída em 1.2s
[TTSService] ✅ Áudio gerado e cacheado: /app/audio_cache/a3f5b8c2...mp3
[TTSService] Latência total: 1.3s
```

---

## Troubleshooting

### Problema: Pod não consegue montar EFS

```bash
# Verificar Mount Targets
aws efs describe-mount-targets --file-system-id fs-XXXXXXXX --region sa-east-1

# Verificar Security Group
aws ec2 describe-security-groups --group-ids sg-XXXXXXXXX --region sa-east-1

# Verificar se EFS CSI Driver está rodando
kubectl get pods -n kube-system | grep efs-csi

# Verificar logs do CSI Driver
kubectl logs -n kube-system -l app=efs-csi-controller
```

### Problema: Cache não está sendo compartilhado

```bash
# Verificar PVC criado corretamente
kubectl get pvc -n c-tv

# Verificar se volume é RWX
kubectl describe pvc c-tv-audio-cache -n c-tv | grep "Access Modes"

# Verificar arquivos no EFS de dentro do pod
kubectl exec -n c-tv c-tv-polly-xxx -- ls -lh /app/audio_cache/
```

### Problema: Custo alto no AWS Polly

```bash
# Verificar taxa de cache hit nos logs
kubectl logs -n c-tv c-tv-polly-xxx | grep "Cache HIT" | wc -l
kubectl logs -n c-tv c-tv-polly-xxx | grep "Cache MISS" | wc -l

# Verificar se EFS está acessível
kubectl exec -n c-tv c-tv-polly-xxx -- df -h /app/audio_cache/

# Verificar permissões de escrita
kubectl exec -n c-tv c-tv-polly-xxx -- touch /app/audio_cache/test.txt
```

---

## Próximos Passos

1. ✅ **Infraestrutura criar EFS** (conforme `SOLICITACAO_EFS.md`)
2. ✅ **Infraestrutura fornecer FileSystemId**: `fs-XXXXXXXX`
3. ⏳ **Desenvolvimento configurar StorageClass e PVC**
4. ⏳ **Desenvolvimento atualizar Deployment para montar EFS**
5. ⏳ **Validação e testes de cache compartilhado**
6. ⏳ **Monitoramento e ajuste de performance**

---

## Referências

- [AWS EFS Documentation](https://docs.aws.amazon.com/efs/)
- [EFS CSI Driver for Kubernetes](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [AWS Polly Documentation](https://docs.aws.amazon.com/polly/)
- [IRSA - IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

---

**Documento gerado em**: 2025-11-18
**Versão**: 1.0
**Cluster**: prod-viver (EKS sa-east-1)
**Namespace**: c-tv
