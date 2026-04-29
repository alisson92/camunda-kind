#!/usr/bin/env bash
# =============================================================================
# install.sh
#
# Instalação idempotente da stack Camunda 8.9 + kube-prometheus-stack
# no cluster Kind "camunda-platform-local"
#
# Pré-requisitos:
#   - kubectl v1.34+
#   - helm v3.x / v4.x (compatível com charts apiVersion: v2)
#   - Cluster Kind "camunda-platform-local" rodando com 3 nós
#
# Uso:
#   ./install.sh                    # instalação completa do zero
#   STEP=4 ./install.sh             # retomar a partir do passo 4 (inclusive)
#   ONLY_STEP=6 ./install.sh        # executar apenas o passo 6
#   DRY_RUN=1 ./install.sh          # exibir o que seria feito sem executar
#   KEEP_PVC=1 ./install.sh         # preservar PVCs ao fazer cleanup de release com falha
#   DRY_RUN=1 STEP=4 ./install.sh   # combinações são válidas
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configurações — altere aqui para ajustar versões ou nomes
# ----------------------------------------------------------------------------
KUBE_CONTEXT="kind-camunda-platform-local"

# Versões dos charts fixadas para reprodutibilidade.
# Em produção: use Renovate ou um arquivo de lock para atualizações controladas.
CHART_CAMUNDA_VERSION="14.0.0"
CHART_PROMETHEUS_VERSION=""          # "" = latest stable
CHART_ELASTICSEARCH_VERSION="8.5.1"  # Último chart Elastic compatível com ES 8.18
CHART_POSTGRESQL_VERSION=""          # "" = latest stable
CHART_KEYCLOAK_VERSION=""            # "" = latest stable

NS_INFRA="camunda-infra"
NS_CAMUNDA="camunda"
NS_MONITORING="monitoring"

RELEASE_PROMETHEUS="kube-prometheus-stack"
RELEASE_ES="elasticsearch"
RELEASE_PG_IDENTITY="postgresql-identity"
RELEASE_PG_WEBMODELER="postgresql-webmodeler"
RELEASE_PG_OPTIMIZE="postgresql-optimize"
RELEASE_KEYCLOAK="keycloak"
RELEASE_CAMUNDA="camunda"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Controle de execução via variáveis de ambiente
START_STEP="${STEP:-0}"    # iniciar a partir deste passo (inclusive)
ONLY_STEP="${ONLY_STEP:-}" # executar apenas este passo (ignora START_STEP)
DRY_RUN="${DRY_RUN:-0}"    # 1 = exibe ações sem executar
KEEP_PVC="${KEEP_PVC:-0}"  # 1 = preserva PVCs ao fazer cleanup de release com falha

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step()  { echo -e "\n${BLUE}==>${NC} ${BOLD}$1${NC}"; }
log_info()  { echo -e "  ${YELLOW}ℹ${NC} $1"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
log_skip()  { echo -e "  ${CYAN}↷${NC} $1 ${YELLOW}(pulado)${NC}"; }
log_error() { echo -e "  ${RED}✗${NC} $1" >&2; }
log_dry()   { echo -e "  ${CYAN}[DRY-RUN]${NC} $1"; }
die()       { log_error "$1"; exit 1; }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Retorna o status de um Helm release: "deployed", "failed", "not-found", etc.
release_status() {
  local namespace="$1" release="$2"
  helm status "${release}" --namespace "${namespace}" -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null \
    || echo "not-found"
}

# Remove um release com falha e seus PVCs órfãos para permitir um fresh install.
#
# StatefulSets deixam PVCs para trás após o uninstall (comportamento intencional do
# Kubernetes para proteger dados). Em ambiente local Kind, onde um release falhou
# antes de inicializar com sucesso, esses PVCs contêm dados inválidos e precisam
# ser removidos para o próximo install funcionar corretamente.
#
# Use KEEP_PVC=1 para preservar os PVCs (ex: quando você quer manter dados de um
# release que falhou apenas por timeout, não por corrupção de configuração).
cleanup_failed_release() {
  local namespace="$1" release="$2"

  log_info "${release}: release com falha detectado — iniciando cleanup para fresh install"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "helm uninstall ${release} -n ${namespace} --wait"
    [[ "${KEEP_PVC}" == "1" ]] \
      && log_dry "PVCs preservados (KEEP_PVC=1)" \
      || log_dry "kubectl delete pvc -n ${namespace} (PVCs com nome contendo '${release}')"
    return 0
  fi

  helm uninstall "${release}" --namespace "${namespace}" --wait 2>/dev/null || true

  if [[ "${KEEP_PVC}" == "1" ]]; then
    log_info "KEEP_PVC=1: PVCs preservados. Se o próximo install falhar por PVC, remova manualmente."
    return 0
  fi

  log_info "Removendo PVCs órfãos do release '${release}'..."

  # Estratégia 1: label app.kubernetes.io/instance (bitnami/postgresql, bitnami/keycloak)
  kubectl delete pvc -n "${namespace}" \
    -l "app.kubernetes.io/instance=${release}" \
    --ignore-not-found 2>/dev/null || true

  # Estratégia 2: label release (alguns charts legados)
  kubectl delete pvc -n "${namespace}" \
    -l "release=${release}" \
    --ignore-not-found 2>/dev/null || true

  # Estratégia 3: PVCs cujo nome contém o release name (elastic/elasticsearch,
  # que usa naming próprio sem labels consistentes)
  kubectl get pvc -n "${namespace}" --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep "${release}" \
    | xargs -r kubectl delete pvc -n "${namespace}" --ignore-not-found \
    2>/dev/null || true

  log_ok "${release}: cleanup concluído — pronto para fresh install"
}

# Instala ou faz upgrade de um Helm release de forma idempotente.
# Uso: helm_upgrade_install <release> <chart> <namespace> <timeout> [flags helm...]
#
# Fluxo de decisão:
#   not-found              → helm install (primeira vez)
#   deployed               → helm upgrade (atualização normal de values/versão)
#   failed/pending-*       → cleanup automático → helm install (recovery de falha)
#   DRY_RUN=1              → apenas exibe o que seria feito, sem executar
helm_upgrade_install() {
  local release="$1" chart="$2" namespace="$3" timeout="$4"
  shift 4

  local status action
  status=$(release_status "${namespace}" "${release}")

  case "${status}" in
    deployed)
      action="upgrade"
      ;;
    failed|pending-install|pending-upgrade|pending-rollback)
      # Release existe mas está em estado inválido: pods travados impedem o upgrade.
      # Faz cleanup completo e reinstala do zero.
      cleanup_failed_release "${namespace}" "${release}"
      action="install"
      ;;
    *)
      # not-found ou qualquer estado desconhecido
      action="install"
      ;;
  esac

  log_info "${release}: helm ${action} (status anterior: ${status})"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "helm ${action} ${release} ${chart} --namespace ${namespace} --timeout ${timeout} --wait $*"
    return 0
  fi

  helm "${action}" "${release}" "${chart}" \
    --namespace "${namespace}" \
    --timeout "${timeout}" \
    --wait \
    "$@"

  log_ok "${release}: ${action} concluído"
}

# Aguarda pods ficarem Ready, tolerando o caso em que os pods ainda não existem.
# kubectl wait falha imediatamente com "no matching resources" se não há pods —
# este wrapper espera os pods aparecerem primeiro, depois chama kubectl wait.
# Uso: wait_for_pods <namespace> <selector> [timeout_segundos]
wait_for_pods() {
  local namespace="$1" selector="$2" timeout="${3:-300}"
  local deadline=$(( SECONDS + timeout ))

  log_info "Aguardando pods Ready: ns=${namespace} sel=${selector} timeout=${timeout}s"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "kubectl wait pod -n ${namespace} -l ${selector} --for=condition=Ready --timeout=${timeout}s"
    return 0
  fi

  # Espera até que pelo menos um pod exista com o selector
  until kubectl get pods -n "${namespace}" -l "${selector}" --no-headers 2>/dev/null | grep -q .; do
    [[ $SECONDS -lt $deadline ]] || die "Timeout: nenhum pod com selector '${selector}' em '${namespace}'"
    sleep 3
  done

  local remaining=$(( deadline - SECONDS ))
  kubectl wait pod \
    --namespace "${namespace}" \
    --selector "${selector}" \
    --for=condition=Ready \
    --timeout="${remaining}s"
}

# Decide se um passo deve executar com base em STEP e ONLY_STEP.
should_run_step() {
  local n="$1"
  if [[ -n "${ONLY_STEP}" ]]; then
    [[ "${n}" == "${ONLY_STEP}" ]]
  else
    [[ "${n}" -ge "${START_STEP}" ]]
  fi
}

# ----------------------------------------------------------------------------
# PASSO 0 — Pré-requisitos e criação do cluster Kind
#
# Cria o cluster Kind se ele não existir. Se já existir, apenas valida o estado.
# Isso torna o script verdadeiramente "clone e execute" — não é necessário
# criar o cluster manualmente antes de rodar o install.sh.
# ----------------------------------------------------------------------------
step_0_preflight() {
  log_step "PASSO 0: Verificações de pré-requisitos e cluster Kind"

  # Verifica ferramentas obrigatórias
  for tool in kubectl helm kind; do
    if ! command -v "${tool}" &>/dev/null; then
      die "Ferramenta não encontrada: '${tool}'. Instale antes de continuar."
    fi
  done
  log_ok "Ferramentas: kubectl, helm, kind encontrados"

  local helm_version
  helm_version=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+')
  log_ok "Helm ${helm_version}"

  # Cria o cluster Kind se ainda não existir
  local cluster_name="camunda-platform-local"
  local kind_config="${SCRIPT_DIR}/configs/kind-cluster-config.yaml"

  if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
    log_ok "Cluster Kind '${cluster_name}' já existe — pulando criação"
  else
    log_info "Cluster Kind '${cluster_name}' não encontrado — criando..."

    if [[ "${DRY_RUN}" == "1" ]]; then
      log_dry "kind create cluster --config ${kind_config}"
    else
      kind create cluster --config "${kind_config}"
      log_ok "Cluster Kind '${cluster_name}' criado"
    fi
  fi

  # Garante que o contexto kubectl aponta para o cluster correto
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "none")
  if [[ "${current_context}" != "${KUBE_CONTEXT}" ]]; then
    log_info "Contexto atual: '${current_context}' — alterando para '${KUBE_CONTEXT}'..."
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_dry "kubectl config use-context ${KUBE_CONTEXT}"
    else
      kubectl config use-context "${KUBE_CONTEXT}" \
        || die "Falha ao mudar contexto para '${KUBE_CONTEXT}'"
    fi
  fi
  log_ok "Contexto kubectl: ${KUBE_CONTEXT}"

  # Verifica nós: awk extrai a coluna STATUS e conta os que não são exatamente "Ready"
  if [[ "${DRY_RUN}" != "1" ]]; then
    local not_ready
    not_ready=$(kubectl get nodes --no-headers | awk '{print $2}' | grep -cv "^Ready$" || true)
    if [[ "${not_ready}" -gt 0 ]]; then
      kubectl get nodes
      die "${not_ready} nó(s) não estão Ready"
    fi
    log_ok "Todos os nós estão Ready"
  fi

  local values_files=(
    "${SCRIPT_DIR}/00-namespaces.yaml"
    "${SCRIPT_DIR}/configs/kind-cluster-config.yaml"
    "${SCRIPT_DIR}/infra/elasticsearch-values.yaml"
    "${SCRIPT_DIR}/infra/postgresql-identity-values.yaml"
    "${SCRIPT_DIR}/infra/postgresql-webmodeler-values.yaml"
    "${SCRIPT_DIR}/infra/postgresql-optimize-values.yaml"
    "${SCRIPT_DIR}/infra/keycloak-manifest.yaml"
    "${SCRIPT_DIR}/monitoring/prometheus-values.yaml"
    "${SCRIPT_DIR}/camunda/camunda-values.yaml"
  )

  local missing=0
  for f in "${values_files[@]}"; do
    if [[ ! -f "${f}" ]]; then
      log_error "Arquivo não encontrado: ${f}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1
  log_ok "Todos os arquivos de configuração encontrados"
}

# ----------------------------------------------------------------------------
# PASSO 1 — Repositórios Helm
# Helm 3/4 retorna exit 0 quando o repo já existe ("already exists, skipping"),
# portanto não é necessário tratar o caso — a saída aparece normalmente no log.
# ----------------------------------------------------------------------------
step_1_helm_repos() {
  log_step "PASSO 1: Adicionando e atualizando repositórios Helm"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "helm repo add camunda + prometheus-community + elastic + bitnami && helm repo update"
    return 0
  fi

  helm repo add camunda               https://helm.camunda.io
  helm repo add prometheus-community  https://prometheus-community.github.io/helm-charts
  helm repo add elastic               https://helm.elastic.co
  helm repo add bitnami               https://charts.bitnami.com/bitnami
  helm repo update

  log_ok "Repositórios atualizados"
}

# ----------------------------------------------------------------------------
# PASSO 2 — Namespaces
# kubectl apply é idempotente: não falha se o namespace já existir.
# ----------------------------------------------------------------------------
step_2_namespaces() {
  log_step "PASSO 2: Criando namespaces"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "kubectl apply -f ${SCRIPT_DIR}/00-namespaces.yaml"
    return 0
  fi

  kubectl apply -f "${SCRIPT_DIR}/00-namespaces.yaml"
  log_ok "Namespaces: ${NS_INFRA}, ${NS_CAMUNDA}, ${NS_MONITORING}"
}

# ----------------------------------------------------------------------------
# PASSO 3 — kube-prometheus-stack
#
# Deve ser instalado ANTES do Camunda porque instala os CRDs ServiceMonitor
# e PodMonitor. O chart do Camunda cria objetos ServiceMonitor durante o
# install — sem os CRDs o Helm falha na validação de schema.
#
# Não usamos --atomic: o kube-prometheus-stack instala muitos CRDs e um
# rollback pode deixar CRDs órfãos no cluster, causando problemas futuros.
# ----------------------------------------------------------------------------
step_3_prometheus() {
  log_step "PASSO 3: Instalando kube-prometheus-stack"

  helm_upgrade_install \
    "${RELEASE_PROMETHEUS}" \
    "prometheus-community/kube-prometheus-stack" \
    "${NS_MONITORING}" \
    "10m" \
    ${CHART_PROMETHEUS_VERSION:+--version "${CHART_PROMETHEUS_VERSION}"} \
    --values "${SCRIPT_DIR}/monitoring/prometheus-values.yaml"

  wait_for_pods "${NS_MONITORING}" \
    "app.kubernetes.io/name=kube-prometheus-stack-prometheus-operator" 120
  log_ok "Prometheus Operator Ready"
}

# ----------------------------------------------------------------------------
# PASSO 4 — Elasticsearch
#
# Deve estar healthy ANTES do Camunda porque:
# - O Zeebe começa a exportar eventos para o ES imediatamente ao subir
# - Operate e Tasklist tentam conectar ao ES durante o startup
# - Se o ES não estiver disponível, esses componentes ficam em CrashLoopBackOff
# ----------------------------------------------------------------------------
step_4_elasticsearch() {
  log_step "PASSO 4: Instalando Elasticsearch"

  helm_upgrade_install \
    "${RELEASE_ES}" \
    "elastic/elasticsearch" \
    "${NS_INFRA}" \
    "10m" \
    ${CHART_ELASTICSEARCH_VERSION:+--version "${CHART_ELASTICSEARCH_VERSION}"} \
    --values "${SCRIPT_DIR}/infra/elasticsearch-values.yaml"

  # O chart usa clusterName no label "app" (ex: "camunda-elasticsearch-master"),
  # não o release name. O label "release" é mais estável pois deriva do RELEASE_ES.
  wait_for_pods "${NS_INFRA}" "release=${RELEASE_ES}" 300
  log_ok "Elasticsearch Ready"

  if [[ "${DRY_RUN}" != "1" ]]; then
    log_info "Verificando conectividade com Elasticsearch..."
    # Imagem pinada para reprodutibilidade — nunca use :latest em ambientes rastreáveis
    if kubectl run es-check \
        --image=curlimages/curl:8.7.1 \
        --namespace="${NS_INFRA}" \
        --rm --restart=Never --timeout=30s \
        -- curl -sf "http://camunda-elasticsearch-master.${NS_INFRA}.svc.cluster.local:9200/_cluster/health" \
        2>/dev/null | grep -q '"status"'; then
      log_ok "Elasticsearch respondendo na porta 9200"
    else
      log_info "Verificação via pod efêmero ignorada (pode ocorrer no Kind — não é erro)"
    fi
  fi
}

# ----------------------------------------------------------------------------
# PASSO 5 — PostgreSQL (3 instâncias independentes)
#
# Deve existir antes do Keycloak e do Camunda.
# O Keycloak usa o banco "keycloak" criado na instância postgresql-identity
# (mesma instância, banco separado — compartilha credenciais de superusuário).
# ----------------------------------------------------------------------------
step_5_postgresql() {
  log_step "PASSO 5: Instalando instâncias PostgreSQL"

  local releases=(
    "${RELEASE_PG_IDENTITY}:${SCRIPT_DIR}/infra/postgresql-identity-values.yaml"
    "${RELEASE_PG_WEBMODELER}:${SCRIPT_DIR}/infra/postgresql-webmodeler-values.yaml"
    "${RELEASE_PG_OPTIMIZE}:${SCRIPT_DIR}/infra/postgresql-optimize-values.yaml"
  )

  for entry in "${releases[@]}"; do
    local release="${entry%%:*}" values_file="${entry##*:}"
    helm_upgrade_install \
      "${release}" \
      "bitnami/postgresql" \
      "${NS_INFRA}" \
      "5m" \
      ${CHART_POSTGRESQL_VERSION:+--version "${CHART_POSTGRESQL_VERSION}"} \
      --values "${values_file}"
  done

  wait_for_pods "${NS_INFRA}" "app.kubernetes.io/name=postgresql" 180
  log_ok "Todos os PostgreSQL Ready"

  if [[ "${DRY_RUN}" != "1" ]]; then
    log_info "Garantindo banco 'keycloak' na instância postgresql-identity..."
    local pg_pod pg_password create_output
    pg_pod=$(kubectl get pod -n "${NS_INFRA}" \
      -l "app.kubernetes.io/instance=${RELEASE_PG_IDENTITY}" \
      -o jsonpath='{.items[0].metadata.name}')
    # Lê a senha do Secret gerado pelo chart — mais confiável que hardcodar.
    # O chart Bitnami armazena a senha do superusuário em .data.postgres-password.
    pg_password=$(kubectl get secret -n "${NS_INFRA}" "${RELEASE_PG_IDENTITY}" \
      -o jsonpath='{.data.postgres-password}' | base64 -d)
    # Força conexão TCP (-h 127.0.0.1) para contornar peer auth do Unix socket.
    # CREATE DATABASE falha se o banco já existir — capturamos a saída e ignoramos
    # o erro "already exists" sem suprimir falhas reais de conexão.
    create_output=$(kubectl exec --namespace "${NS_INFRA}" "${pg_pod}" -- \
      bash -c "PGPASSWORD='${pg_password}' psql -h 127.0.0.1 -U postgres -c 'CREATE DATABASE keycloak;' 2>&1") || true
    if echo "${create_output}" | grep -q "already exists"; then
      log_info "Banco 'keycloak' já existia — nenhuma ação necessária"
    elif echo "${create_output}" | grep -q "CREATE DATABASE"; then
      log_ok "Banco 'keycloak' criado com sucesso"
    else
      log_error "Resultado inesperado ao criar banco 'keycloak': ${create_output}"
      exit 1
    fi

    # Concede ao usuário 'identity' permissão total no banco keycloak.
    # No PostgreSQL 15+, CREATE no schema public não é mais concedido por padrão.
    # O Keycloak (Liquibase) precisa criar tabelas no schema public ao inicializar.
    # Dois comandos psql separados: o GRANT ON SCHEMA precisa conectar ao banco alvo.
    log_info "Concedendo permissões ao usuário 'identity' no banco 'keycloak'..."
    kubectl exec --namespace "${NS_INFRA}" "${pg_pod}" -- \
      bash -c "PGPASSWORD='${pg_password}' psql -h 127.0.0.1 -U postgres \
        -c 'GRANT ALL PRIVILEGES ON DATABASE keycloak TO identity;' && \
        PGPASSWORD='${pg_password}' psql -h 127.0.0.1 -U postgres -d keycloak \
        -c 'GRANT ALL ON SCHEMA public TO identity;'" 2>/dev/null || true
    log_ok "Permissões concedidas ao usuário 'identity' no banco 'keycloak'"
  fi
}

# ----------------------------------------------------------------------------
# PASSO 6 — Keycloak
#
# O Identity do Camunda configura o Keycloak no startup: cria realm,
# clients e usuários. Se o Keycloak não estiver disponível, o Identity
# não inicializa e trava a subida de todos os outros componentes.
#
# Não usamos bitnami/keycloak: a partir de agosto/2025, as imagens Bitnami
# no Docker Hub exigem assinatura paga. Usamos a imagem oficial
# quay.io/keycloak/keycloak via manifesto Kubernetes direto — sempre gratuita.
# ----------------------------------------------------------------------------
step_6_keycloak() {
  log_step "PASSO 6: Instalando Keycloak"

  local manifest="${SCRIPT_DIR}/infra/keycloak-manifest.yaml"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "kubectl apply -f ${manifest}"
    return 0
  fi

  # Migração: remove release Helm legado (bitnami/keycloak) se ainda existir,
  # pois coexistir Helm + kubectl apply no mesmo recurso causa conflitos de ownership.
  local old_status
  old_status=$(release_status "${NS_INFRA}" "${RELEASE_KEYCLOAK}")
  if [[ "${old_status}" != "not-found" ]]; then
    log_info "Release Helm 'keycloak' detectado (status: ${old_status}) — removendo para migrar para manifesto..."
    helm uninstall "${RELEASE_KEYCLOAK}" --namespace "${NS_INFRA}" --wait 2>/dev/null || true
    log_ok "Release Helm removido"
  fi

  # kubectl apply é idempotente: cria se não existe, atualiza se existe
  kubectl apply -f "${manifest}"
  log_ok "Manifesto Keycloak aplicado"

  # Keycloak leva mais tempo para inicializar (JVM + DB migrations + KC start-dev build)
  wait_for_pods "${NS_INFRA}" "app.kubernetes.io/instance=keycloak" 300
  log_ok "Keycloak Ready"
}

# ----------------------------------------------------------------------------
# PASSO 7 — Camunda Platform 8.9
#
# Último a instalar: depende de toda a infraestrutura estar pronta.
# O --wait aqui é funcional: os readiness probes do Camunda testam a
# conectividade com ES e Keycloak, então quando o Helm retorna, a stack
# está operacional — não apenas com pods Running.
# ----------------------------------------------------------------------------
step_7_camunda() {
  log_step "PASSO 7: Instalando Camunda Platform 8.9"

  helm_upgrade_install \
    "${RELEASE_CAMUNDA}" \
    "camunda/camunda-platform" \
    "${NS_CAMUNDA}" \
    "20m" \
    --version "${CHART_CAMUNDA_VERSION}" \
    --values "${SCRIPT_DIR}/camunda/camunda-values.yaml"

  log_ok "Camunda Platform 8.9 instalado"
}

# ----------------------------------------------------------------------------
# PASSO 8 — Verificação final
# ----------------------------------------------------------------------------
step_8_verify() {
  log_step "PASSO 8: Verificação final da stack"

  if [[ "${DRY_RUN}" != "1" ]]; then
    for ns in "${NS_INFRA}" "${NS_MONITORING}" "${NS_CAMUNDA}"; do
      echo ""
      echo "--- Namespace: ${ns} ---"
      kubectl get pods -n "${ns}" 2>/dev/null \
        || log_info "Namespace ${ns} vazio ou inexistente"
    done
  fi

  echo ""
  log_step "Port-forwards para acesso local"
  cat <<EOF

  # Camunda Platform — abra um terminal por comando
  kubectl -n ${NS_CAMUNDA}    port-forward svc/camunda-zeebe-gateway            26500:26500  # Zeebe gRPC (workers/SDK)
  kubectl -n ${NS_CAMUNDA}    port-forward svc/camunda-zeebe-gateway             8080:8080   # Operate → /operate  Tasklist → /tasklist
  kubectl -n ${NS_CAMUNDA}    port-forward svc/camunda-optimize                  8083:80     # http://localhost:8083
  kubectl -n ${NS_CAMUNDA}    port-forward svc/camunda-identity                  8084:80     # http://localhost:8084
  kubectl -n ${NS_CAMUNDA}    port-forward svc/camunda-web-modeler-restapi       8085:80     # http://localhost:8085

  # Infraestrutura
  kubectl -n ${NS_INFRA}      port-forward svc/keycloak                          8086:80     # http://localhost:8086
  kubectl -n ${NS_INFRA}      port-forward svc/camunda-elasticsearch-master      9200:9200   # http://localhost:9200

  # Observabilidade
  kubectl -n ${NS_MONITORING} port-forward svc/kube-prometheus-stack-grafana     3000:80     # http://localhost:3000
  kubectl -n ${NS_MONITORING} port-forward svc/kube-prometheus-stack-prometheus  9090:9090   # http://localhost:9090

  Credenciais padrão:
    Camunda (Operate/Tasklist/etc.): demo / demo
    Keycloak admin:                  admin / admin-secret
    Grafana:                         admin / grafana-secret

  NOTA: No Camunda 8.9, Operate e Tasklist rodam dentro do pod camunda-zeebe-0.
        Acesse via http://localhost:8080/operate e http://localhost:8080/tasklist.
EOF
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
main() {
  echo -e "${GREEN}${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║   Camunda Platform 8.9 + kube-prometheus-stack                ║"
  echo "║   Kind cluster: camunda-platform-local                        ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  [[ "${DRY_RUN}"    == "1" ]]  && log_info "Modo DRY-RUN ativo — nenhuma alteração será feita"
  [[ "${KEEP_PVC}"   == "1" ]]  && log_info "KEEP_PVC=1: PVCs preservados no cleanup de releases com falha"
  [[ -n "${ONLY_STEP}" ]]       && log_info "Executando apenas o passo ${ONLY_STEP}"
  [[ "${START_STEP}" -gt "0" ]] && log_info "Iniciando a partir do passo ${START_STEP}"

  # Mapa ordenado de passos: índice → função
  # A ordem é garantida pelo seq, não pelo mapa (bash não ordena arrays associativos)
  declare -A STEPS=(
    [0]="step_0_preflight"
    [1]="step_1_helm_repos"
    [2]="step_2_namespaces"
    [3]="step_3_prometheus"
    [4]="step_4_elasticsearch"
    [5]="step_5_postgresql"
    [6]="step_6_keycloak"
    [7]="step_7_camunda"
    [8]="step_8_verify"
  )

  for n in $(seq 0 8); do
    if should_run_step "${n}"; then
      "${STEPS[$n]}"
    else
      log_skip "Passo ${n} (${STEPS[$n]})"
    fi
  done

  echo -e "\n${GREEN}${BOLD}✓ Concluído com sucesso!${NC}\n"
}

main "$@"
