# Camunda Platform 8.9 — Kind Local Environment

Ambiente local completo do Camunda Platform 8.9 Self-Managed rodando em Kubernetes via Kind,
com monitoramento via kube-prometheus-stack e infraestrutura (Elasticsearch, PostgreSQL, Keycloak)
gerenciada como serviços independentes — espelhando a arquitetura de produção no EKS.

## Contexto e motivação

A partir do Camunda 8.9, os sub-charts de infraestrutura embutidos (Elasticsearch, PostgreSQL, Keycloak)
foram desabilitados por padrão. O modelo oficial de produção passou a exigir que esses serviços sejam
provisionados e gerenciados independentemente antes do deploy do Camunda. Este projeto reproduz
exatamente esse modelo localmente.

## Arquitetura

```
Cluster Kind: camunda-platform-local (1 control-plane + 2 workers)
│
├── Namespace: camunda-infra          ← Infraestrutura gerenciada independentemente
│   ├── elasticsearch                 ← ES 8.18 (backend de dados do Camunda)
│   ├── postgresql-identity           ← PG dedicado ao Identity
│   ├── postgresql-webmodeler         ← PG dedicado ao Web Modeler
│   ├── postgresql-optimize           ← PG dedicado ao Optimize
│   └── keycloak                      ← IdP SSO (Keycloak 26.x)
│
├── Namespace: camunda                ← Camunda Platform 8.9
│   ├── zeebe (StatefulSet)           ← Orchestration cluster: Zeebe + Operate + Tasklist
│   │   ├── perfil: broker            ← Motor de orquestração RAFT
│   │   ├── perfil: operate           ← UI de operação de processos (integrado ao Zeebe no 8.9)
│   │   └── perfil: tasklist          ← UI de tarefas humanas (integrado ao Zeebe no 8.9)
│   ├── optimize                      ← Analytics e relatórios
│   ├── identity                      ← Gerenciamento de identidades e RBAC
│   ├── web-modeler                   ← Editor BPMN/DMN/Form online
│   └── connectors                    ← Runtime de conectores
│
└── Namespace: monitoring             ← Observabilidade
    ├── prometheus                    ← Coleta de métricas (via ServiceMonitors)
    ├── grafana                       ← Dashboards e visualização
    └── alertmanager                  ← Roteamento de alertas
```

> **Mudança importante no Camunda 8.9:** Operate e Tasklist foram integrados ao Orchestration Cluster
> (pod `camunda-zeebe-0`). Não existem mais deployments separados para esses componentes.
> Ambos são acessados via `camunda-zeebe-gateway:8080` com paths `/operate` e `/tasklist`.

## Pré-requisitos

| Ferramenta | Versão mínima | Verificação |
|---|---|---|
| Docker Desktop / Docker Engine | 24.x+ | `docker --version` |
| Kind | v0.30.0+ | `kind version` |
| kubectl | v1.34+ | `kubectl version --client` |
| Helm | v4.x (compatível com charts v2) | `helm version --short` |

### Recursos mínimos do Docker

| Recurso | Mínimo |
|---|---|
| CPUs | 5 |
| Memória | 12 GB |
| Disco | 30 GB livres |

Verifique com `docker info | grep -E 'CPUs|Memory'`.

## Estrutura do projeto

```
.
├── README.md
├── CLAUDE.md                              ← Contexto para uso com Claude Code
├── install.sh                             ← Script de instalação sequencial
├── 00-namespaces.yaml                     ← Definição dos namespaces
│
├── infra/                                 ← Helm values da infraestrutura externa
│   ├── elasticsearch-values.yaml          ← chart: elastic/elasticsearch
│   ├── keycloak-values.yaml               ← chart: bitnami/keycloak
│   ├── postgresql-identity-values.yaml    ← chart: bitnami/postgresql
│   ├── postgresql-webmodeler-values.yaml  ← chart: bitnami/postgresql
│   └── postgresql-optimize-values.yaml   ← chart: bitnami/postgresql
│
├── monitoring/
│   └── prometheus-values.yaml             ← chart: prometheus-community/kube-prometheus-stack
│
└── camunda/
    └── camunda-values.yaml                ← chart: camunda/camunda-platform v14.0.0
```

## Instalação

### 1. Clonar e executar

```bash
git clone https://github.com/alisson92/camunda-kind.git
cd camunda-kind
./install.sh
```

O script cuida de tudo na ordem correta: cria o cluster Kind (se ainda não existir),
adiciona os repositórios Helm, instala cada componente com health check entre os passos
e exibe os port-forwards ao final.

Tempo estimado: **15–25 minutos** (varia conforme velocidade de download das imagens).

### Retomar uma instalação interrompida

Caso o script falhe em algum passo, você pode retomar de onde parou:

```bash
STEP=4 ./install.sh     # inicia a partir do passo 4 (inclusive)
ONLY_STEP=6 ./install.sh  # executa apenas o passo 6
DRY_RUN=1 ./install.sh  # exibe o que seria feito sem executar nada
```

| Passo | O que faz |
|---|---|
| 0 | Verifica ferramentas, cria o cluster Kind se necessário |
| 1 | Adiciona repositórios Helm |
| 2 | Cria namespaces |
| 3 | kube-prometheus-stack (instala CRDs ServiceMonitor antes do Camunda) |
| 4 | Elasticsearch |
| 5 | PostgreSQL ×3 + banco `keycloak` |
| 6 | Keycloak |
| 7 | Camunda Platform 8.9 |
| 8 | Verificação final + port-forwards |

### `publicIssuerUrl` — único valor que pode precisar de ajuste

Por padrão está configurado como `http://localhost:8086/auth/realms/camunda-platform`,
que funciona com o port-forward do Keycloak na porta 8086 (conforme exibido no passo 8).
Se você precisar de uma porta diferente, edite antes de rodar:

```yaml
# camunda/camunda-values.yaml
global:
  identity:
    auth:
      publicIssuerUrl: "http://localhost:<SUA_PORTA>/auth/realms/camunda-platform"
```

## Acesso aos serviços

Todos os serviços são acessados via `kubectl port-forward`. Abra um terminal por serviço
ou use uma ferramenta como [kubefwd](https://github.com/txn2/kubefwd) para fazer todos de uma vez.

### Camunda Platform

```bash
# Zeebe gRPC (workers e clientes zbctl/SDK)
kubectl -n camunda port-forward svc/camunda-zeebe-gateway 26500:26500

# Orchestration Cluster (Operate + Tasklist + REST API) → http://localhost:8080
# - Operate  → http://localhost:8080/operate
# - Tasklist → http://localhost:8080/tasklist
kubectl -n camunda port-forward svc/camunda-zeebe-gateway 8080:8080

# Optimize → http://localhost:8083
kubectl -n camunda port-forward svc/camunda-optimize 8083:80

# Identity → http://localhost:8084
kubectl -n camunda port-forward svc/camunda-identity 8084:80

# Web Modeler → http://localhost:8085
kubectl -n camunda port-forward svc/camunda-web-modeler-restapi 8085:80
```

**Credenciais padrão:** `demo` / `demo`

### Infraestrutura

```bash
# Keycloak Admin UI → http://localhost:8086  (admin / admin-secret)
kubectl -n camunda-infra port-forward svc/keycloak 8086:80

# Elasticsearch → http://localhost:9200
kubectl -n camunda-infra port-forward svc/camunda-elasticsearch-master 9200:9200
```

**Keycloak:** `admin` / `admin-secret`

### Monitoramento

```bash
# Grafana → http://localhost:3000
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Prometheus → http://localhost:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# Alertmanager → http://localhost:9093
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

**Grafana:** `admin` / `grafana-secret`

## Operações comuns

### Verificar saúde da stack

```bash
# Status geral de todos os pods
kubectl get pods -A | grep -E 'camunda|monitoring'

# Verificar se o Prometheus está coletando métricas do Camunda
# Após port-forward do Prometheus: http://localhost:9090/targets
# Todos os targets do Camunda devem aparecer como UP

# Verificar ServiceMonitors descobertos
kubectl get servicemonitors -n camunda
kubectl get servicemonitors -n camunda-infra
```

### Reiniciar um componente

```bash
# Exemplo: reiniciar o Identity sem afetar os outros
kubectl -n camunda rollout restart deployment/camunda-identity
kubectl -n camunda rollout status deployment/camunda-identity

# Reiniciar o Orchestration Cluster (Zeebe + Operate + Tasklist)
kubectl -n camunda rollout restart statefulset/camunda-zeebe
kubectl -n camunda rollout status statefulset/camunda-zeebe
```

### Ver logs de um componente

```bash
# Logs do Zeebe Broker
kubectl -n camunda logs -l app.kubernetes.io/component=zeebe --tail=100 -f

# Logs do Identity (útil para troubleshoot de autenticação)
kubectl -n camunda logs -l app.kubernetes.io/component=identity --tail=100 -f
```

### Atualizar um values e fazer upgrade

```bash
# Exemplo: alterar recursos do Operate e aplicar
# 1. Edite camunda/camunda-values.yaml
# 2. Execute o upgrade:
helm upgrade camunda camunda/camunda-platform \
  --namespace camunda \
  --version 14.0.0 \
  --values camunda/camunda-values.yaml \
  --timeout 15m \
  --wait
```

### Teardown completo

```bash
# Remove todos os releases Helm (mantém os PVCs com os dados)
helm uninstall camunda -n camunda
helm uninstall keycloak -n camunda-infra
helm uninstall postgresql-identity -n camunda-infra
helm uninstall postgresql-webmodeler -n camunda-infra
helm uninstall postgresql-optimize -n camunda-infra
helm uninstall elasticsearch -n camunda-infra
helm uninstall kube-prometheus-stack -n monitoring

# Remove os PVCs (dados perdidos — irreversível)
kubectl delete pvc --all -n camunda
kubectl delete pvc --all -n camunda-infra
kubectl delete pvc --all -n monitoring

# OU: destrói o cluster inteiro (mais rápido, apaga tudo)
kind delete cluster --name camunda-platform-local
```

## Diferenças em relação à produção (EKS)

| Aspecto | Este ambiente (Kind) | Produção (EKS) |
|---|---|---|
| StorageClass | `standard` (local-path, hostPath) | `gp3` (EBS CSI Driver) |
| Acesso externo | `kubectl port-forward` | ALB Ingress Controller |
| Zeebe replicas | 1 broker, 1 partição | 3 brokers, 3+ partições |
| Elasticsearch | Single-node, sem auth | Multi-node, xpack.security |
| PostgreSQL | Standalone, sem réplica | RDS Multi-AZ ou operador |
| Keycloak | Single-replica, HTTP | Multi-replica, HTTPS |
| Secrets | Plaintext no values | Sealed Secrets ou ESO |
| Recursos | Reduzidos (limits conservadores) | Sizing por workload real |
| PVC reclaim | `Delete` (dados perdidos com PVC) | `Retain` |

## Versões

| Componente | Versão |
|---|---|
| Camunda Platform | 8.9.0 |
| Helm chart camunda-platform | 14.0.0 |
| Elasticsearch | 8.18.0 |
| Keycloak | 26.x |
| PostgreSQL | 15.x |
| kube-prometheus-stack | latest stable |
| Kubernetes (Kind node) | v1.34.0 |

## Referências

- [Camunda 8.9 Helm Chart Version Matrix](https://helm.camunda.io/camunda-platform/version-matrix/camunda-8.9)
- [Camunda Self-Managed Docs](https://docs.camunda.io/docs/self-managed/about-self-managed/)
- [Camunda Deployment References (GitHub)](https://github.com/camunda/camunda-deployment-references)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Mudança nos sub-charts Bitnami — Camunda 8.9](https://camunda.com/blog/2026/03/camunda-8-helm-chart-and-bitnami-sub-charts/)
