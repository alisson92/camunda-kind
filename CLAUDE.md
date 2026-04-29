# CLAUDE.md — Contexto para Claude Code

Este arquivo é lido automaticamente pelo Claude Code ao ser invocado neste diretório.
Ele fornece o contexto necessário para que o Claude entenda o projeto, o ambiente
e as convenções antes de qualquer interação.

## O que é este projeto

Ambiente local do **Camunda Platform 8.9 Self-Managed** rodando em **Kubernetes via Kind**,
com **kube-prometheus-stack** para observabilidade. Toda a infraestrutura (Elasticsearch,
PostgreSQL, Keycloak) é provisionada como serviços independentes — reproduzindo o modelo
de produção no EKS onde cada serviço é gerenciado separadamente.

**Objetivo principal:** validar a stack Camunda 8.9 localmente antes de subir para staging/EKS.

## Ambiente de execução

- **OS:** WSL2 (Ubuntu) no Windows
- **Cluster:** Kind `camunda-platform-local` — 1 control-plane + 2 workers, node `kindest/node:v1.34.0`
- **Contexto kubectl:** `kind-camunda-platform-local`
- **Helm:** v4.x (compatível com charts `apiVersion: v2`)
- **Helm CLI recomendado para chart Camunda 14.0.0:** 3.20.1 (Helm 4.x é compatível)

Antes de qualquer comando kubectl ou helm, verifique o contexto:
```bash
kubectl config current-context
# Esperado: kind-camunda-platform-local
```

## Versões fixadas

| Componente | Chart | App Version |
|---|---|---|
| camunda-platform | 14.0.0 | 8.9.0 |
| elasticsearch | elastic/elasticsearch 8.5.1 | 8.18.0 |
| postgresql (×3) | bitnami/postgresql latest | 15.x |
| keycloak | bitnami/keycloak latest | 26.x |
| kube-prometheus-stack | prometheus-community latest | — |

## Namespaces e o que roda em cada um

| Namespace | Conteúdo | Helm releases |
|---|---|---|
| `camunda-infra` | Elasticsearch, 3× PostgreSQL, Keycloak | `elasticsearch`, `postgresql-identity`, `postgresql-webmodeler`, `postgresql-optimize`, `keycloak` |
| `camunda` | Todos os componentes Camunda 8.9 | `camunda` |
| `monitoring` | Prometheus, Grafana, Alertmanager | `kube-prometheus-stack` |

## Arquitetura de infraestrutura externa (CRÍTICO)

A partir do Camunda 8.9, os sub-charts embutidos de infraestrutura foram desabilitados por padrão.
Os seguintes serviços são instalados **antes** do Camunda via charts separados no namespace `camunda-infra`:

- **Elasticsearch** (`elasticsearch-master.camunda-infra.svc.cluster.local:9200`) — sem autenticação (xpack.security desabilitado para local)
- **PostgreSQL Identity** (`postgresql-identity.camunda-infra.svc.cluster.local:5432`) — database: `identity`, user: `identity`
- **PostgreSQL Web Modeler** (`postgresql-webmodeler.camunda-infra.svc.cluster.local:5432`) — database: `webmodeler`, user: `webmodeler`
- **PostgreSQL Optimize** (`postgresql-optimize.camunda-infra.svc.cluster.local:5432`) — database: `optimize`, user: `optimize`
- **Keycloak** (`keycloak.camunda-infra.svc.cluster.local:80`) — usa o PostgreSQL do Identity (database separado: `keycloak`)

No `camunda-values.yaml`, as seções `elasticsearch.enabled`, `postgresql.enabled` e `keycloak.enabled`
estão todas como `false` — isso é intencional e correto.

## Ordem de instalação (nunca altere)

```
kube-prometheus-stack → elasticsearch → postgresql (×3) → keycloak → camunda
```

O kube-prometheus-stack instala os CRDs `ServiceMonitor` e `PodMonitor`. O chart do Camunda
cria objetos `ServiceMonitor` durante o install — se os CRDs não existirem, o install falha.

## Credenciais locais

> Todas as credenciais são para uso local apenas. Nunca use estes valores em produção.

| Serviço | Usuário | Senha |
|---|---|---|
| Camunda (Operate/Tasklist/etc.) | `demo` | `demo` |
| Keycloak admin | `admin` | `admin-secret` |
| PostgreSQL superuser | `postgres` | `postgres-admin-secret` |
| PostgreSQL Identity app user | `identity` | `identity-secret` |
| PostgreSQL Web Modeler app user | `webmodeler` | `webmodeler-secret` |
| PostgreSQL Optimize app user | `optimize` | `optimize-secret` |
| Grafana | `admin` | `grafana-secret` |

## ServiceMonitors e integração Prometheus

Todos os componentes Camunda têm `serviceMonitor.enabled: true` com:
```yaml
labels:
  release: kube-prometheus-stack
```

Este label é o seletor que o Prometheus Operator usa para descobrir ServiceMonitors.
Se um ServiceMonitor não aparecer no Prometheus (`/targets`), verifique se este label está presente.

O Prometheus Operator está configurado para descobrir ServiceMonitors nos namespaces
`camunda`, `camunda-infra` e `monitoring`.

## StorageClass

O Kind usa `standard` (provisioner: `rancher.io/local-path`) como StorageClass default.
Todos os PVCs do projeto usam `storageClassName: ""` (string vazia = usa o default do cluster).
Em EKS, o default seria `gp2` ou `gp3` — ao migrar, ajuste explicitamente nos values.

## Regras para sugestões e modificações

### Sempre verificar antes de agir
```bash
# Verificar estado atual do cluster antes de qualquer mudança
kubectl get pods -A | grep -E 'camunda|monitoring'
helm list -A
```

### Comandos destrutivos exigem dry-run primeiro
Qualquer comando que modifique ou delete recursos em `camunda` ou `camunda-infra`
deve ser precedido de dry-run:
```bash
# Exemplo de dry-run para helm upgrade
helm upgrade camunda camunda/camunda-platform \
  --namespace camunda \
  --version 14.0.0 \
  --values camunda/camunda-values.yaml \
  --dry-run
```

### Nunca use `--force-replace` sem confirmação explícita
O `--force-replace` (antigo `--force` no Helm 3) recria recursos destrutivamente.
Sempre peça confirmação antes de sugerir esse flag.

### Probes de readiness antes de declarar sucesso
Após qualquer `helm install` ou `helm upgrade`, verificar:
```bash
kubectl rollout status deployment/<nome> -n <namespace> --timeout=5m
```

### Alertas proativos — sempre avisar quando identificar:
- Pods sem `resources.requests` ou `resources.limits` definidos
- `replicaCount: 1` em componentes stateful sem PodDisruptionBudget
- Secrets em plaintext nos values (aceitável neste ambiente local, mas deve ser documentado)
- `image.tag: latest` — nunca usar, sempre pinnar versão
- PVCs com `ReclaimPolicy: Delete` em contexto de dados persistentes críticos

## Comandos de diagnóstico frequentes

```bash
# Saúde geral da stack
kubectl get pods -n camunda
kubectl get pods -n camunda-infra
kubectl get pods -n monitoring

# Eventos recentes (útil para debugar pod em CrashLoopBackOff)
kubectl events -n camunda --types=Warning

# Verificar se ServiceMonitors estão sendo processados pelo Prometheus
kubectl get servicemonitors -n camunda -o wide

# Verificar targets no Prometheus (após port-forward 9090)
# http://localhost:9090/targets

# Logs de um componente específico
kubectl -n camunda logs -l app.kubernetes.io/component=zeebe --tail=200 -f
kubectl -n camunda logs -l app.kubernetes.io/component=operate --tail=200 -f
kubectl -n camunda logs -l app.kubernetes.io/component=identity --tail=200 -f

# Verificar conectividade com Elasticsearch
kubectl -n camunda-infra exec -it \
  $(kubectl get pod -n camunda-infra -l app=elasticsearch-master -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s localhost:9200/_cluster/health | python3 -m json.tool

# Verificar conectividade com PostgreSQL Identity
kubectl -n camunda-infra exec -it \
  $(kubectl get pod -n camunda-infra -l "app.kubernetes.io/instance=postgresql-identity" -o jsonpath='{.items[0].metadata.name}') \
  -- bash -c "PGPASSWORD=identity-secret psql -U identity -d identity -c '\l'"
```

## Arquitetura de componentes — Camunda 8.9 (IMPORTANTE)

A partir do chart 14.0.0, **Operate e Tasklist foram integrados ao Orchestration Cluster**.
Não existem mais deployments separados `camunda-operate` e `camunda-tasklist`.
O pod `camunda-zeebe-0` roda Zeebe (broker + gateway) + Operate + Tasklist como perfis unificados.

| Camunda 8.8 (chart < 14) | Camunda 8.9 (chart 14.0.0) |
|---|---|
| Deployment: `camunda-operate` | Integrado ao pod `camunda-zeebe-0` |
| Deployment: `camunda-tasklist` | Integrado ao pod `camunda-zeebe-0` |
| Service: `camunda-operate` | Não existe — usar `camunda-zeebe-gateway:8080/operate` |
| Service: `camunda-tasklist` | Não existe — usar `camunda-zeebe-gateway:8080/tasklist` |

Os perfis ativos são controlados por `orchestration.profiles` no values:
```yaml
orchestration:
  profiles:
    broker: true
    admin: true
    operate: true
    tasklist: true
```

## Port-forwards de referência

```bash
# Zeebe gRPC (porta original do gateway)
kubectl -n camunda port-forward svc/camunda-zeebe-gateway 26500:26500

# Orchestration Cluster — porta única para Operate, Tasklist e REST API
# Operate  → http://localhost:8080/operate
# Tasklist → http://localhost:8080/tasklist
# Admin UI → http://localhost:8080/admin
kubectl -n camunda port-forward svc/camunda-zeebe-gateway 8080:8080

# Optimize → http://localhost:8083
kubectl -n camunda port-forward svc/camunda-optimize 8083:80

# Identity → http://localhost:8084
kubectl -n camunda port-forward svc/camunda-identity 8084:80

# Web Modeler → http://localhost:8085
kubectl -n camunda port-forward svc/camunda-web-modeler-restapi 8085:80

# Keycloak Admin → http://localhost:8086  (admin / admin-secret)
kubectl -n camunda-infra port-forward svc/keycloak 8086:80

# Elasticsearch → http://localhost:9200
kubectl -n camunda-infra port-forward svc/camunda-elasticsearch-master 9200:9200

# Grafana → http://localhost:3000  (admin / grafana-secret)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Prometheus → http://localhost:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

## Ponto de atenção: publicIssuerUrl do Keycloak

O campo `global.identity.auth.publicIssuerUrl` em `camunda/camunda-values.yaml`
deve apontar para o endereço **que o browser vai usar** para redirect SSO.
Com port-forward do Keycloak na porta `8086`, o valor correto é:

```
http://localhost:8086/auth/realms/camunda-platform
```

Se o login SSO não funcionar, este é o primeiro lugar a verificar.

## Próximas evoluções planejadas

- [ ] Importar dashboards oficiais do Camunda no Grafana
- [ ] Configurar Alertmanager com regras de alerta para os componentes Camunda
- [ ] Documentar processo de upgrade de 8.9.x para próxima minor
- [ ] Adicionar script de teardown e recriação rápida do ambiente
- [ ] Migrar secrets de plaintext para Sealed Secrets (preparação para staging)
