#!/usr/bin/env bash
#==============================================================================
#  Script ....: instala_dns_web.sh
#  Versão ....: 1.0
#  Autor .....: Matheus Alencar - RM 572185
#
#  OBJETIVO
#    Automatizar, de ponta a ponta e sem tarefas manuais, a criação de:
#      1. Um servidor DNS autoritativo (BIND) para um domínio informado pelo
#         usuário, com os registros (A, AAAA, CNAME, MX, TXT, NS) e endereços
#         também informados durante a execução;
#      2. Um servidor Web (Apache ou NGINX, à escolha do usuário);
#      3. A publicação de um template HTML baixado da Internet como página
#         padrão do servidor Web.
#
#  DISTRIBUIÇÕES SUPORTADAS
#    - Família Debian: Debian, Ubuntu, Linux Mint, Kali (apt-get)
#    - Família Red Hat: RHEL, CentOS, Rocky, AlmaLinux, Fedora (dnf/yum)
#
#  COMO EXECUTAR
#    chmod +x instala_dns_web.sh
#    sudo ./instala_dns_web.sh
#
#  ARQUIVOS GERADOS
#    - Log completo da execução ......: /var/log/instala_dns_web_<data>.log
#    - Backup das configs originais ..: /var/backups/instala_dns_web_<data>/
#
#  ORGANIZAÇÃO DO CÓDIGO
#    1. Variáveis globais
#    2. Funções de saída na tela (info / aviso / erro / sucesso)
#    3. Funções utilitárias (perguntas, validações, serviços)
#    4. Etapas da automação (uma função por etapa)
#    5. Tarefas adicionais (espaço reservado para o dia da Global)
#    6. Fluxo principal (main)
#==============================================================================

# -e: aborta em erro | -E: herda o trap de erro nas funções
# -u: erro em variável não definida | pipefail: falha em qualquer parte do pipe
set -Eeuo pipefail

#==============================================================================
# 1. VARIÁVEIS GLOBAIS
#==============================================================================
DATA_HORA="$(date +%Y%m%d_%H%M%S)"; readonly DATA_HORA
readonly LOG="/var/log/instala_dns_web_${DATA_HORA}.log"
readonly DIR_BACKUP="/var/backups/instala_dns_web_${DATA_HORA}"

# Template HTML padrão (pode ser trocado na execução pela URL usada em aula).
# Aceita: arquivo .zip, .tar.gz/.tgz ou uma página .html simples.
readonly TEMPLATE_PADRAO="https://github.com/StartBootstrap/startbootstrap-agency/archive/refs/heads/master.zip"

# Cores para a saída (desativadas se a saída não for um terminal)
if [[ -t 1 ]]; then
    VERDE=$'\e[1;32m'; AMARELO=$'\e[1;33m'; VERMELHO=$'\e[1;31m'
    AZUL=$'\e[1;34m';  CIANO=$'\e[1;36m';   NEGRITO=$'\e[1m'; RESET=$'\e[0m'
else
    VERDE=""; AMARELO=""; VERMELHO=""; AZUL=""; CIANO=""; NEGRITO=""; RESET=""
fi

# Preenchidas durante a execução
FAMILIA=""              # debian | rhel
GERENCIADOR=""          # apt-get | dnf | yum
WEB=""                  # apache | nginx
DOMINIO=""              # ex.: empresa.lab
IP_SERVIDOR=""          # IP deste servidor (DNS e Web)
URL_TEMPLATE=""
CRIAR_REVERSA="s"
CONFIGURAR_RESOLVER="s"
MODO_PASSO_A_PASSO="n"
ZONA_REVERSA=""
ETAPA_ATUAL=0
TOTAL_ETAPAS=9

# Registros DNS informados pelo usuário (vetores paralelos)
declare -a REG_NOME=() REG_TIPO=() REG_VALOR=() REG_PRIO=()

# Caminhos/nomes que mudam conforme a distribuição (ver definir_caminhos)
BIND_SERVICO=""; BIND_CONF_INCLUDE=""; BIND_DIR_ZONAS=""; BIND_GRUPO=""
WEB_PACOTE="";   WEB_SERVICO="";       WEB_ROOT="";      WEB_USUARIO=""

#==============================================================================
# 2. FUNÇÕES DE SAÍDA NA TELA (informações / avisos)
#    Tudo o que é exibido também é gravado no arquivo de log.
#==============================================================================
log()     { { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; } 2>/dev/null || true; }
info()    { printf '%s[INFO]%s  %s\n'  "$AZUL"     "$RESET" "$*"; log "INFO:  $*"; }
aviso()   { printf '%s[AVISO]%s %s\n'  "$AMARELO"  "$RESET" "$*"; log "AVISO: $*"; }
sucesso() { printf '%s[OK]%s    %s\n'  "$VERDE"    "$RESET" "$*"; log "OK:    $*"; }
erro()    { printf '%s[ERRO]%s  %s\n'  "$VERMELHO" "$RESET" "$*" >&2; log "ERRO:  $*"; }

# Cabeçalho de cada etapa. No modo passo a passo, pede confirmação antes.
titulo() {
    ETAPA_ATUAL=$((ETAPA_ATUAL + 1))
    printf '\n%s======================================================================%s\n' "$CIANO" "$RESET"
    printf '%s ETAPA %d/%d - %s%s\n' "$NEGRITO" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "$*" "$RESET"
    printf '%s======================================================================%s\n' "$CIANO" "$RESET"
    log "===== ETAPA ${ETAPA_ATUAL}/${TOTAL_ETAPAS}: $* ====="
    if [[ $MODO_PASSO_A_PASSO == "s" ]]; then
        confirmar "Deseja continuar com esta etapa?" s || { aviso "Execução interrompida pelo usuário."; exit 0; }
    fi
}

# Executa um comando mostrando o que está sendo feito; a saída técnica vai
# para o log. Se o comando falhar, o trap de erro exibe o motivo.
executar() {
    local descricao=$1; shift
    info "$descricao"
    log "CMD:   $*"
    "$@" >>"$LOG" 2>&1 </dev/null
}

# Tratamento de erros: mostra a linha, o comando e o final do log
tratar_erro() {
    local codigo=$? linha=$1 comando=$2
    erro "Falha na linha ${linha} (código ${codigo}): ${comando}"
    if [[ -f $LOG ]]; then
        printf '%s--- Últimas linhas do log (%s) ---%s\n' "$AMARELO" "$LOG" "$RESET" >&2
        tail -n 15 "$LOG" >&2 || true
    fi
    erro "Corrija o problema e execute o script novamente (as configs originais estão em ${DIR_BACKUP})."
    exit "$codigo"
}
trap 'tratar_erro "$LINENO" "$BASH_COMMAND"' ERR
trap 'echo; aviso "Execução cancelada pelo usuário (Ctrl+C)."; exit 130' INT

#==============================================================================
# 3. FUNÇÕES UTILITÁRIAS
#==============================================================================

# Remove espaços no início e no fim de um texto
aparar() { local t=$1; t="${t#"${t%%[![:space:]]*}"}"; printf '%s' "${t%"${t##*[![:space:]]}"}"; }

# confirmar "Pergunta" [s|n]  -> retorna 0 (sim) ou 1 (não). 2º parâmetro = padrão.
confirmar() {
    local pergunta=$1 padrao=${2:-n} resposta opcoes
    [[ $padrao == "s" ]] && opcoes="[S/n]" || opcoes="[s/N]"
    while true; do
        read -r -p "${CIANO}?${RESET} ${pergunta} ${opcoes}: " resposta || { echo; erro "Entrada encerrada."; exit 1; }
        resposta=$(aparar "${resposta:-$padrao}")
        case "${resposta,,}" in
            s|sim|y|yes) log "PERGUNTA: $pergunta -> sim"; return 0 ;;
            n|nao|não|no) log "PERGUNTA: $pergunta -> não"; return 1 ;;
            *) aviso "Resposta inválida. Digite 's' para sim ou 'n' para não." ;;
        esac
    done
}

# perguntar VARIAVEL "Pergunta" ["valor padrão"] -> grava a resposta na variável
perguntar() {
    local __destino=$1 pergunta=$2 padrao=${3:-} resposta
    if [[ -n $padrao ]]; then
        read -r -p "${CIANO}?${RESET} ${pergunta} [${padrao}]: " resposta || { echo; erro "Entrada encerrada."; exit 1; }
        resposta=${resposta:-$padrao}
    else
        read -r -p "${CIANO}?${RESET} ${pergunta}: " resposta || { echo; erro "Entrada encerrada."; exit 1; }
    fi
    resposta=$(aparar "$resposta")
    log "PERGUNTA: $pergunta -> $resposta"
    printf -v "$__destino" '%s' "$resposta"
}

# ---------- Validações ----------
ipv4_valido() {
    local ip=$1 octeto
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octeto in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octeto <= 255 )) || return 1
    done
}
ipv6_valido()    { [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:.]+$ ]]; }
dominio_valido() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
host_valido()    { [[ $1 == "@" || $1 =~ ^(\*|[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9])?)(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9])?)*$ ]]; }

# Converte o nome digitado em nome relativo à zona
#   "empresa.lab" -> "@"   |   "www.empresa.lab" -> "www"   |   "www" -> "www"
normalizar_nome() {
    local n=${1,,}; n=${n%.}
    if [[ -z $n || $n == "@" || $n == "$DOMINIO" ]]; then echo "@"
    elif [[ $n == *".$DOMINIO" ]]; then echo "${n%".$DOMINIO"}"
    else echo "$n"; fi
}

# Normaliza o destino de CNAME/MX/NS
#   "mail" -> "mail" (relativo à zona) | "smtp.google.com" -> "smtp.google.com."
normalizar_alvo() {
    local v=${1,,}
    if [[ $v == "@" || $v == "$DOMINIO" || $v == "$DOMINIO." ]]; then echo "@"
    elif [[ $v == *. ]]; then echo "$v"
    elif [[ $v == *.* ]]; then echo "$v."
    else echo "$v"; fi
}

# Retorna 0 se já existir algum registro com esse nome (opcionalmente de um tipo)
nome_existe() {
    local nome=$1 tipo=${2:-} i
    for i in "${!REG_NOME[@]}"; do
        if [[ ${REG_NOME[$i]} == "$nome" ]] && [[ -z $tipo || ${REG_TIPO[$i]} == "$tipo" ]]; then
            return 0
        fi
    done
    return 1
}

adicionar_registro() { REG_NOME+=("$1"); REG_TIPO+=("$2"); REG_VALOR+=("$3"); REG_PRIO+=("${4:-}"); }

# Nome completo (FQDN) de um registro, para os testes com dig
fqdn() { [[ $1 == "@" ]] && echo "$DOMINIO" || echo "$1.$DOMINIO"; }

# ---------- Gerenciamento de serviços (com ou sem systemd, ex.: WSL) ----------
tem_systemd() { [[ -d /run/systemd/system ]]; }

servico() {   # servico <start|stop|restart|enable|disable> <nome>
    local acao=$1 nome=$2
    if tem_systemd; then
        systemctl "$acao" "$nome"
    else
        case $acao in
            enable|disable) return 0 ;;   # sem systemd não há "enable"
            *) service "$nome" "$acao" ;;
        esac
    fi
}

servico_ativo() {
    local nome=$1
    if tem_systemd; then systemctl is-active --quiet "$nome"
    else service "$nome" status >/dev/null 2>&1; fi
}

servico_existe() {
    local nome=$1
    if tem_systemd; then systemctl list-unit-files "${nome}.service" 2>/dev/null | grep -q "^${nome}.service"
    else [[ -x /etc/init.d/$nome ]]; fi
}

# Copia um arquivo/diretório para a pasta de backup antes de alterá-lo
fazer_backup() {
    local origem=$1
    [[ -e $origem ]] || return 0
    mkdir -p "${DIR_BACKUP}$(dirname "$origem")"
    cp -a "$origem" "${DIR_BACKUP}${origem}"
    log "BACKUP: $origem -> ${DIR_BACKUP}${origem}"
}

# Para o outro servidor Web (se estiver ativo), evitando conflito na porta 80.
# Precisa ocorrer ANTES da instalação: no Ubuntu, o apt falha se o novo
# servidor não conseguir iniciar por porta ocupada.
parar_web_concorrente() {
    local outro
    if [[ $WEB == "apache" ]]; then outro="nginx"
    else outro=$([[ $FAMILIA == "debian" ]] && echo apache2 || echo httpd); fi
    if servico_existe "$outro" && servico_ativo "$outro"; then
        aviso "O serviço '${outro}' está ativo e ocupa a porta 80; ele será parado e desabilitado."
        executar "Parando ${outro}..." servico stop "$outro"
        servico disable "$outro" >>"$LOG" 2>&1 || true
    fi
}

# Em máquinas com IPv6 desativado, o NGINX não inicia com "listen [::]:80".
ipv6_disponivel() { grep -q . /proc/net/if_inet6 2>/dev/null; }

ajustar_ipv6_nginx() {
    [[ $WEB == "nginx" ]] || return 0
    ipv6_disponivel && return 0
    local arq
    for arq in /etc/nginx/sites-available/default /etc/nginx/nginx.conf /etc/nginx/conf.d/default.conf; do
        [[ -f $arq ]] && grep -qE '^[[:space:]]*listen[[:space:]]+\[::\]' "$arq" || continue
        fazer_backup "$arq"
        sed -i -E 's/^([[:space:]]*)(listen[[:space:]]+\[::\].*)$/\1# \2  # IPv6 indisponivel - desativado pelo script/' "$arq"
        aviso "IPv6 desativado nesta máquina: linha 'listen [::]' comentada em ${arq}."
    done
}

#==============================================================================
# 4. ETAPAS DA AUTOMAÇÃO
#==============================================================================

banner() {
    clear 2>/dev/null || true
    cat <<EOF
${CIANO}######################################################################
#                                                                    #
#      AUTOMAÇÃO DE SERVIDOR DNS (BIND) + SERVIDOR WEB + TEMPLATE    #
#                                                                    #
######################################################################${RESET}

Este script irá, de forma automática:
  ${VERDE}1.${RESET} Verificar o ambiente (usuário root, distribuição, Internet);
  ${VERDE}2.${RESET} Solicitar o domínio, os tipos de registro DNS e seus endereços;
  ${VERDE}3.${RESET} Instalar o BIND e o servidor Web escolhido (Apache ou NGINX);
  ${VERDE}4.${RESET} Criar a zona DNS direta (e, se desejado, a reversa);
  ${VERDE}5.${RESET} Baixar um template HTML da Internet e publicá-lo como página padrão;
  ${VERDE}6.${RESET} Liberar as portas no firewall e testar tudo ao final.

${AMARELO}Atenção:${RESET} arquivos de configuração existentes serão salvos em backup antes
de qualquer alteração. Pressione Ctrl+C a qualquer momento para cancelar.

EOF
}

# ---------------------------------------------------------------------------
# ETAPA 1 - Verificação do ambiente
# ---------------------------------------------------------------------------
verificar_ambiente() {
    titulo "Verificação do ambiente"

    # Detecta a distribuição pelo /etc/os-release
    # shellcheck disable=SC1091
    source /etc/os-release
    local ids=" ${ID:-} ${ID_LIKE:-} "
    if [[ $ids == *" debian "* || $ids == *" ubuntu "* ]]; then
        FAMILIA="debian"; GERENCIADOR="apt-get"
    elif [[ $ids =~ (rhel|fedora|centos|rocky|almalinux) ]]; then
        FAMILIA="rhel"
        GERENCIADOR=$(command -v dnf >/dev/null && echo dnf || echo yum)
    else
        erro "Distribuição não suportada: ${PRETTY_NAME:-desconhecida}."
        exit 1
    fi
    sucesso "Sistema detectado: ${PRETTY_NAME:-$ID} (família ${FAMILIA}, gerenciador ${GERENCIADOR})."

    if tem_systemd; then
        sucesso "Gerenciador de serviços: systemd."
    else
        aviso "systemd não detectado (ex.: WSL/contêiner). Os serviços serão iniciados com 'service'."
    fi

    # Teste de conectividade (necessária para baixar pacotes e o template)
    info "Testando acesso à Internet..."
    if curl -s -o /dev/null --max-time 8 https://github.com 2>/dev/null \
       || wget -q --spider --timeout=8 https://github.com 2>/dev/null \
       || getent hosts github.com >/dev/null 2>&1; then
        sucesso "Acesso à Internet OK."
    else
        aviso "Não foi possível confirmar o acesso à Internet."
        confirmar "Deseja continuar mesmo assim?" n || exit 1
    fi
}

# Define pacotes, serviços e diretórios conforme distribuição e servidor Web
definir_caminhos() {
    if [[ $FAMILIA == "debian" ]]; then
        BIND_CONF_INCLUDE="/etc/bind/named.conf.local"
        BIND_DIR_ZONAS="/etc/bind/zones"
        BIND_GRUPO="bind"
        WEB_USUARIO="www-data"
        WEB_ROOT="/var/www/html"
        if [[ $WEB == "apache" ]]; then WEB_PACOTE="apache2"; WEB_SERVICO="apache2"
        else WEB_PACOTE="nginx"; WEB_SERVICO="nginx"; fi
    else
        BIND_CONF_INCLUDE="/etc/named.conf"
        BIND_DIR_ZONAS="/var/named"
        BIND_GRUPO="named"
        BIND_SERVICO="named"
        if [[ $WEB == "apache" ]]; then
            WEB_PACOTE="httpd"; WEB_SERVICO="httpd"; WEB_USUARIO="apache"; WEB_ROOT="/var/www/html"
        else
            WEB_PACOTE="nginx"; WEB_SERVICO="nginx"; WEB_USUARIO="nginx"; WEB_ROOT="/usr/share/nginx/html"
        fi
    fi
}

# ---------------------------------------------------------------------------
# ETAPA 2 - Coleta de informações (domínio, registros e endereços)
# ---------------------------------------------------------------------------

# Pergunta os dados de UM registro DNS e o adiciona à lista
coletar_registro() {
    local tipo nome valor prio="" opcao
    echo
    echo "  Tipos disponíveis: ${NEGRITO}1)${RESET} A   ${NEGRITO}2)${RESET} AAAA   ${NEGRITO}3)${RESET} CNAME   ${NEGRITO}4)${RESET} MX   ${NEGRITO}5)${RESET} TXT   ${NEGRITO}6)${RESET} NS"
    perguntar opcao "Tipo do registro (número ou nome)"
    case "${opcao^^}" in
        1|A) tipo="A" ;;   2|AAAA) tipo="AAAA" ;;  3|CNAME) tipo="CNAME" ;;
        4|MX) tipo="MX" ;; 5|TXT) tipo="TXT" ;;    6|NS) tipo="NS" ;;
        *) aviso "Tipo inválido: '$opcao'."; return 1 ;;
    esac

    local padrao_nome=""
    [[ $tipo == "MX" || $tipo == "TXT" ]] && padrao_nome="@"
    perguntar nome "Nome do host (ex.: www, ftp, mail | @ = o próprio ${DOMINIO})" "$padrao_nome"
    nome=$(normalizar_nome "$nome")
    host_valido "$nome" || { aviso "Nome de host inválido: '$nome'."; return 1; }

    # Regras do DNS: CNAME não pode coexistir com outros registros no mesmo nome
    if [[ $tipo == "CNAME" ]]; then
        [[ $nome == "@" ]] && { aviso "Não é permitido CNAME na raiz do domínio (@). Use um registro A."; return 1; }
        nome_existe "$nome" && { aviso "Já existe registro para '$nome'; CNAME precisa ser exclusivo."; return 1; }
    elif nome_existe "$nome" "CNAME"; then
        aviso "'$nome' já é um CNAME; não é possível adicionar outro registro com esse nome."; return 1
    fi

    case $tipo in
        A)
            perguntar valor "Endereço IPv4 de $(fqdn "$nome")" "$IP_SERVIDOR"
            ipv4_valido "$valor" || { aviso "Endereço IPv4 inválido: '$valor'."; return 1; } ;;
        AAAA)
            perguntar valor "Endereço IPv6 de $(fqdn "$nome")"
            ipv6_valido "$valor" || { aviso "Endereço IPv6 inválido: '$valor'."; return 1; } ;;
        CNAME)
            perguntar valor "Apelido de qual nome? (ex.: www ou servidor.externo.com)"
            [[ -n $valor ]] || { aviso "Destino vazio."; return 1; }
            valor=$(normalizar_alvo "$valor") ;;
        MX)
            perguntar valor "Nome do servidor de e-mail (ex.: mail)" "mail"
            valor=$(normalizar_alvo "$valor")
            perguntar prio "Prioridade do MX (menor = preferido)" "10"
            [[ $prio =~ ^[0-9]{1,5}$ ]] || { aviso "Prioridade inválida."; return 1; }
            if [[ $valor != *. ]] && ! nome_existe "$valor" "A" && [[ $valor != "@" ]]; then
                aviso "Lembrete: crie também um registro A para '$valor' (o MX precisa apontar para um host com IP)."
            fi ;;
        TXT)
            perguntar valor "Texto do registro (ex.: v=spf1 mx -all)"
            [[ -n $valor ]] || { aviso "Texto vazio."; return 1; } ;;
        NS)
            perguntar valor "Servidor de nomes (ex.: ns2 ou ns2.provedor.com)"
            [[ -n $valor ]] || { aviso "Destino vazio."; return 1; }
            valor=$(normalizar_alvo "$valor") ;;
    esac

    printf '  -> %-12s IN %-6s %s %s\n' "$nome" "$tipo" "$prio" "$valor"
    if confirmar "Confirma este registro?" s; then
        adicionar_registro "$nome" "$tipo" "$valor" "$prio"
        sucesso "Registro $tipo para '$(fqdn "$nome")' adicionado."
    else
        aviso "Registro descartado."
    fi
}

# Valida a URL do template e converte o link de um repositório do GitHub
# (https://github.com/usuario/repositorio) no link de download do .zip.
ajustar_url_template() {
    local url=$1
    if [[ ! $url =~ ^https?:// ]]; then
        return 1
    fi
    if [[ $url =~ ^https?://(www\.)?github\.com/([^/]+)/([^/]+)/?$ ]]; then
        local repo=${BASH_REMATCH[3]%.git}
        url="https://github.com/${BASH_REMATCH[2]}/${repo}/archive/HEAD.zip"
    fi
    printf '%s' "$url"
}

pedir_url_template() {
    local url ajustada
    while true; do
        perguntar url "URL do template HTML" "$TEMPLATE_PADRAO"
        if ajustada=$(ajustar_url_template "$url"); then
            [[ $ajustada != "$url" ]] && info "Repositório do GitHub detectado. Será baixado: ${ajustada}"
            URL_TEMPLATE=$ajustada
            return 0
        fi
        aviso "A URL deve começar com http:// ou https:// e apontar para onde o template será BAIXADO"
        aviso "(ex.: link de um .zip ou de um repositório do GitHub). Não é o domínio do seu site."
    done
}

coletar_informacoes() {
    REG_NOME=(); REG_TIPO=(); REG_VALOR=(); REG_PRIO=()

    # --- Servidor Web ---
    echo
    echo "Servidores Web disponíveis: ${NEGRITO}1)${RESET} Apache   ${NEGRITO}2)${RESET} NGINX"
    local opcao
    while true; do
        perguntar opcao "Qual servidor Web deseja instalar?" "1"
        case "${opcao,,}" in
            1|apache|apache2|httpd) WEB="apache"; break ;;
            2|nginx) WEB="nginx"; break ;;
            *) aviso "Opção inválida. Digite 1 ou 2." ;;
        esac
    done
    sucesso "Servidor Web escolhido: ${WEB^^}."

    # --- Domínio ---
    while true; do
        perguntar DOMINIO "Nome do domínio a ser criado (ex.: empresa.lab)"
        DOMINIO=${DOMINIO,,}; DOMINIO=${DOMINIO%.}
        if ! dominio_valido "$DOMINIO"; then
            aviso "Domínio inválido. Use o formato nome.sufixo (ex.: empresa.lab, minhaempresa.com.br)."
            continue
        fi
        if [[ $DOMINIO == *.local ]]; then
            aviso "Domínios '.local' são reservados ao mDNS e podem falhar em alguns clientes. Prefira .lab, .lan ou .corp."
            confirmar "Deseja usar '${DOMINIO}' mesmo assim?" n || continue
        fi
        break
    done
    sucesso "Domínio: ${DOMINIO}"

    # --- IP do servidor (sugere o IP da interface principal) ---
    local ip_detectado
    ip_detectado=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    [[ -z $ip_detectado ]] && ip_detectado=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    while true; do
        perguntar IP_SERVIDOR "Endereço IPv4 deste servidor (DNS/Web)" "${ip_detectado:-}"
        ipv4_valido "$IP_SERVIDOR" && break
        aviso "Endereço IPv4 inválido."
    done

    # Registro obrigatório do próprio servidor de nomes (ns1)
    adicionar_registro "ns1" "A" "$IP_SERVIDOR"
    info "Registros obrigatórios criados automaticamente: SOA, NS (ns1.${DOMINIO}) e ns1 -> ${IP_SERVIDOR}."

    # --- Registros do site ---
    if confirmar "Criar os registros A para '${DOMINIO}' e 'www.${DOMINIO}' (site)?" s; then
        local ip_site
        while true; do
            perguntar ip_site "Endereço IPv4 do site" "$IP_SERVIDOR"
            ipv4_valido "$ip_site" && break
            aviso "Endereço IPv4 inválido."
        done
        adicionar_registro "@"   "A" "$ip_site"
        adicionar_registro "www" "A" "$ip_site"
        sucesso "Registros A '@' e 'www' -> ${ip_site} adicionados."
    fi

    # --- Registros adicionais escolhidos pelo usuário ---
    echo
    info "Agora informe os demais registros DNS (tipo, nome e endereço)."
    while confirmar "Deseja adicionar um registro DNS?" s; do
        coletar_registro || aviso "Registro não adicionado. Tente novamente."
    done

    # --- Template HTML ---
    echo
    info "O template será baixado da Internet (aceita .zip, .tar.gz ou página .html)."
    pedir_url_template

    # --- Opções extras ---
    confirmar "Criar também a zona reversa (PTR) para a rede ${IP_SERVIDOR%.*}.0/24?" s && CRIAR_REVERSA="s" || CRIAR_REVERSA="n"
    confirmar "Configurar este servidor para usar o próprio DNS na resolução do domínio?" s && CONFIGURAR_RESOLVER="s" || CONFIGURAR_RESOLVER="n"
}

mostrar_resumo() {
    local i
    echo
    printf '%s---------------------------- RESUMO ----------------------------%s\n' "$NEGRITO" "$RESET"
    echo "  Servidor Web:          ${WEB^^}"
    echo "  Domínio:               ${DOMINIO}"
    echo "  IP do servidor:        ${IP_SERVIDOR}"
    echo "  Template HTML:         ${URL_TEMPLATE}"
    echo "  Zona reversa:          $([[ $CRIAR_REVERSA == s ]] && echo sim || echo não)"
    echo "  Usar DNS local:        $([[ $CONFIGURAR_RESOLVER == s ]] && echo sim || echo não)"
    echo "  Registros DNS:"
    printf '      %-28s %-6s %s\n' "NOME" "TIPO" "VALOR"
    printf '      %-28s %-6s %s\n' "$DOMINIO" "NS" "ns1.${DOMINIO}."
    for i in "${!REG_NOME[@]}"; do
        printf '      %-28s %-6s %s\n' "$(fqdn "${REG_NOME[$i]}")" "${REG_TIPO[$i]}" \
            "${REG_PRIO[$i]:+${REG_PRIO[$i]} }${REG_VALOR[$i]}"
    done
    printf '%s----------------------------------------------------------------%s\n' "$NEGRITO" "$RESET"
}

etapa_coleta() {
    titulo "Coleta de informações"
    while true; do
        coletar_informacoes
        mostrar_resumo
        if confirmar "As informações estão corretas? Iniciar a instalação?" s; then
            break
        elif confirmar "Deseja preencher as informações novamente?" s; then
            continue
        else
            aviso "Instalação cancelada pelo usuário. Nenhuma alteração foi feita."
            exit 0
        fi
    done
    definir_caminhos
}

# ---------------------------------------------------------------------------
# ETAPA 3 - Instalação dos pacotes
# ---------------------------------------------------------------------------
instalar_pacotes() {
    titulo "Instalação dos pacotes (BIND + ${WEB^^})"
    info "Isso pode levar alguns minutos. Detalhes em: ${LOG}"

    if [[ $FAMILIA == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        local apt_opts=(-y -q -o DPkg::Lock::Timeout=300)
        executar "Atualizando a lista de pacotes (apt-get update)..." apt-get "${apt_opts[@]}" update
        executar "Instalando ferramentas auxiliares (curl, wget, unzip)..." \
            apt-get "${apt_opts[@]}" install curl wget unzip tar ca-certificates iproute2
        executar "Instalando o servidor DNS BIND (bind9)..." apt-get "${apt_opts[@]}" install bind9
        # Utilitário 'dig' (o nome do pacote varia entre versões)
        if ! command -v dig >/dev/null; then
            executar "Instalando o utilitário dig..." apt-get "${apt_opts[@]}" install bind9-dnsutils \
              || executar "Instalando o utilitário dig (dnsutils)..." apt-get "${apt_opts[@]}" install dnsutils
        fi
        parar_web_concorrente
        if ! executar "Instalando o servidor Web (${WEB_PACOTE})..." apt-get "${apt_opts[@]}" install "$WEB_PACOTE"; then
            aviso "A pós-instalação do ${WEB_PACOTE} falhou (comum com IPv6 desativado). Corrigindo..."
            ajustar_ipv6_nginx
            executar "Concluindo a configuração dos pacotes (dpkg --configure -a)..." dpkg --configure -a
        fi

        # Nome do serviço do BIND: 'named' (versões novas) ou 'bind9' (antigas)
        if servico_existe named; then BIND_SERVICO="named"; else BIND_SERVICO="bind9"; fi
    else
        executar "Instalando ferramentas auxiliares..." "$GERENCIADOR" -y install curl wget unzip tar
        executar "Instalando o servidor DNS BIND (bind, bind-utils)..." "$GERENCIADOR" -y install bind bind-utils
        parar_web_concorrente
        executar "Instalando o servidor Web (${WEB_PACOTE})..." "$GERENCIADOR" -y install "$WEB_PACOTE"
    fi
    sucesso "Pacotes instalados. Serviço DNS: ${BIND_SERVICO} | Serviço Web: ${WEB_SERVICO}."
}

# ---------------------------------------------------------------------------
# ETAPA 4 - Configuração do DNS (BIND)
# ---------------------------------------------------------------------------

# Gera o arquivo da zona direta
gerar_zona_direta() {
    local arquivo=$1 serial=$2 i nome tipo valor prio
    {
        echo ";=================================================================="
        echo "; Zona direta: ${DOMINIO}"
        echo "; Gerada automaticamente por instala_dns_web.sh em $(date '+%d/%m/%Y %H:%M')"
        echo ";=================================================================="
        echo "\$TTL 86400"
        echo "@       IN  SOA  ns1.${DOMINIO}. admin.${DOMINIO}. ("
        echo "                 ${serial} ; Serial (AAAAMMDDNN)"
        echo "                 3600       ; Refresh"
        echo "                 1800       ; Retry"
        echo "                 604800     ; Expire"
        echo "                 86400 )    ; TTL de cache negativo"
        echo ";"
        echo "; Servidor de nomes autoritativo"
        echo "@       IN  NS   ns1.${DOMINIO}."
        echo ";"
        echo "; Registros"
        for i in "${!REG_NOME[@]}"; do
            nome=${REG_NOME[$i]}; tipo=${REG_TIPO[$i]}; valor=${REG_VALOR[$i]}; prio=${REG_PRIO[$i]}
            case $tipo in
                MX)  printf '%-15s IN  %-5s %s %s\n' "$nome" "$tipo" "$prio" "$valor" ;;
                TXT) printf '%-15s IN  %-5s "%s"\n'  "$nome" "$tipo" "${valor//\"/\\\"}" ;;
                *)   printf '%-15s IN  %-5s %s\n'    "$nome" "$tipo" "$valor" ;;
            esac
        done
    } >"$arquivo"
}

# Gera o arquivo da zona reversa (PTR) para a rede /24 do servidor
gerar_zona_reversa() {
    local arquivo=$1 serial=$2 rede=${IP_SERVIDOR%.*} i ip
    declare -A usado=()
    {
        echo ";=================================================================="
        echo "; Zona reversa: ${ZONA_REVERSA} (rede ${rede}.0/24)"
        echo "; Gerada automaticamente por instala_dns_web.sh em $(date '+%d/%m/%Y %H:%M')"
        echo ";=================================================================="
        echo "\$TTL 86400"
        echo "@       IN  SOA  ns1.${DOMINIO}. admin.${DOMINIO}. ("
        echo "                 ${serial} 3600 1800 604800 86400 )"
        echo "@       IN  NS   ns1.${DOMINIO}."
        echo ";"
        # Um PTR por IP da mesma rede (o primeiro nome cadastrado para o IP)
        for i in "${!REG_NOME[@]}"; do
            [[ ${REG_TIPO[$i]} == "A" ]] || continue
            ip=${REG_VALOR[$i]}
            [[ ${ip%.*} == "$rede" ]] || continue
            [[ -n ${usado[${ip##*.}]:-} ]] && continue
            usado[${ip##*.}]=1
            printf '%-7s IN  PTR  %s.\n' "${ip##*.}" "$(fqdn "${REG_NOME[$i]}")"
        done
    } >"$arquivo"
}

configurar_bind() {
    titulo "Configuração do servidor DNS (BIND)"
    local serial arquivo_zona arquivo_reversa arquivo_conf_zonas o1 o2 o3
    serial="$(date +%Y%m%d)01"
    mkdir -p "$BIND_DIR_ZONAS" "$DIR_BACKUP"

    arquivo_zona="${BIND_DIR_ZONAS}/db.${DOMINIO}"
    IFS=. read -r o1 o2 o3 _ <<<"$IP_SERVIDOR"
    ZONA_REVERSA="${o3}.${o2}.${o1}.in-addr.arpa"
    arquivo_reversa="${BIND_DIR_ZONAS}/db.${o1}.${o2}.${o3}"

    if [[ $FAMILIA == "debian" ]]; then
        arquivo_conf_zonas="/etc/bind/zones/${DOMINIO}.conf"

        info "Salvando backup das configurações originais do BIND..."
        fazer_backup /etc/bind/named.conf.options
        fazer_backup /etc/bind/named.conf.local

        info "Gravando opções globais em /etc/bind/named.conf.options..."
        cat >/etc/bind/named.conf.options <<'EOF'
// Gerado por instala_dns_web.sh (original salvo no diretório de backup)
options {
    directory "/var/cache/bind";

    // Responde a consultas de qualquer cliente para as zonas locais
    allow-query     { any; };
    listen-on       { any; };
    listen-on-v6    { any; };

    // Recursão (Internet) somente para a própria máquina e redes locais
    recursion yes;
    allow-recursion { localhost; localnets; };
    forwarders      { 8.8.8.8; 1.1.1.1; };

    dnssec-validation auto;
};
EOF
    else
        arquivo_conf_zonas="/etc/named/${DOMINIO}.conf"
        mkdir -p /etc/named

        info "Salvando backup do /etc/named.conf original..."
        fazer_backup /etc/named.conf

        info "Liberando consultas de outros hosts no /etc/named.conf..."
        sed -i -E 's/listen-on port 53 \{[^}]*\};/listen-on port 53 { any; };/' /etc/named.conf
        sed -i -E 's/listen-on-v6 port 53 \{[^}]*\};/listen-on-v6 port 53 { any; };/' /etc/named.conf
        sed -i -E 's/allow-query[[:space:]]+\{[^}]*\};/allow-query     { any; };/' /etc/named.conf
        grep -q 'allow-recursion' /etc/named.conf \
            || sed -i '/^options[[:space:]]*{/a\        allow-recursion { localhost; localnets; };' /etc/named.conf
    fi

    info "Criando a zona direta em ${arquivo_zona}..."
    gerar_zona_direta "$arquivo_zona" "$serial"

    info "Declarando as zonas em ${arquivo_conf_zonas}..."
    {
        echo "// Zonas do domínio ${DOMINIO} - gerado por instala_dns_web.sh"
        echo "zone \"${DOMINIO}\" {"
        echo "    type master;"
        echo "    file \"${arquivo_zona}\";"
        echo "    allow-transfer { none; };"
        echo "};"
    } >"$arquivo_conf_zonas"

    if [[ $CRIAR_REVERSA == "s" ]]; then
        info "Criando a zona reversa ${ZONA_REVERSA} em ${arquivo_reversa}..."
        gerar_zona_reversa "$arquivo_reversa" "$serial"
        {
            echo ""
            echo "zone \"${ZONA_REVERSA}\" {"
            echo "    type master;"
            echo "    file \"${arquivo_reversa}\";"
            echo "    allow-transfer { none; };"
            echo "};"
        } >>"$arquivo_conf_zonas"
    fi

    # Inclui o arquivo de zonas na configuração principal (apenas uma vez)
    if ! grep -qF "include \"${arquivo_conf_zonas}\";" "$BIND_CONF_INCLUDE"; then
        echo "include \"${arquivo_conf_zonas}\";" >>"$BIND_CONF_INCLUDE"
        info "Arquivo de zonas incluído em ${BIND_CONF_INCLUDE}."
    fi

    info "Ajustando dono e permissões dos arquivos de zona..."
    chown root:"$BIND_GRUPO" "$arquivo_zona" "$arquivo_conf_zonas"
    chmod 644 "$arquivo_zona" "$arquivo_conf_zonas"
    if [[ $CRIAR_REVERSA == "s" ]]; then
        chown root:"$BIND_GRUPO" "$arquivo_reversa"; chmod 644 "$arquivo_reversa"
    fi
    command -v restorecon >/dev/null && restorecon -R "$BIND_DIR_ZONAS" /etc/named* >/dev/null 2>&1 || true

    # Validação da sintaxe antes de reiniciar o serviço
    executar "Validando a configuração geral (named-checkconf)..." named-checkconf
    executar "Validando a zona ${DOMINIO} (named-checkzone)..." named-checkzone "$DOMINIO" "$arquivo_zona"
    if [[ $CRIAR_REVERSA == "s" ]]; then
        executar "Validando a zona reversa ${ZONA_REVERSA}..." named-checkzone "$ZONA_REVERSA" "$arquivo_reversa"
    fi
    sucesso "Arquivos de configuração do DNS válidos."

    executar "Habilitando o serviço ${BIND_SERVICO} na inicialização..." servico enable "$BIND_SERVICO" || true
    executar "Reiniciando o serviço ${BIND_SERVICO}..." servico restart "$BIND_SERVICO"
    sleep 2
    servico_ativo "$BIND_SERVICO" && sucesso "Servidor DNS em execução." \
        || aviso "O serviço ${BIND_SERVICO} não aparenta estar ativo; verifique o log."
}

# ---------------------------------------------------------------------------
# ETAPA 5 - Configuração do servidor Web
# ---------------------------------------------------------------------------
configurar_web() {
    titulo "Configuração do servidor Web (${WEB^^})"

    # Garante que nada mais ocupa a porta 80 e que o NGINX funciona sem IPv6
    parar_web_concorrente
    ajustar_ipv6_nginx

    if [[ $WEB == "apache" ]]; then
        # Define o ServerName (remove o aviso 'Could not reliably determine...')
        if [[ $FAMILIA == "debian" ]]; then
            echo "ServerName ${DOMINIO}" >/etc/apache2/conf-available/servername.conf
            executar "Habilitando o ServerName ${DOMINIO} no Apache..." a2enconf servername
            executar "Validando a configuração do Apache..." apache2ctl configtest
        else
            echo "ServerName ${DOMINIO}" >/etc/httpd/conf.d/servername.conf
            executar "Validando a configuração do Apache..." httpd -t
        fi
    else
        executar "Validando a configuração do NGINX..." nginx -t
    fi

    executar "Habilitando o serviço ${WEB_SERVICO} na inicialização..." servico enable "$WEB_SERVICO" || true
    executar "Iniciando o serviço ${WEB_SERVICO}..." servico restart "$WEB_SERVICO"
    sleep 1
    sucesso "Servidor Web ${WEB^^} em execução. Diretório do site: ${WEB_ROOT}"
}

# ---------------------------------------------------------------------------
# ETAPA 6 - Download e publicação do template HTML
# ---------------------------------------------------------------------------

# Baixa e extrai o template. Retorna 0 e o diretório com o index.html em
# $DIR_TEMPLATE, ou 1 em caso de falha.
DIR_TEMPLATE=""
baixar_template() {
    local url=$1 tmp=$2 pacote="$2/pacote" destino="$2/extraido" indice
    rm -rf "$destino" "$pacote"; mkdir -p "$destino"

    info "Baixando: ${url}"
    if ! curl -fsSL --retry 2 --connect-timeout 15 -A "Mozilla/5.0" -o "$pacote" "$url" >>"$LOG" 2>&1; then
        wget -q --timeout=20 -U "Mozilla/5.0" -O "$pacote" "$url" >>"$LOG" 2>&1 \
            || { aviso "Falha no download da URL informada."; return 1; }
    fi
    info "Download concluído ($(du -h "$pacote" | cut -f1)). Identificando o formato..."

    if unzip -tq "$pacote" >/dev/null 2>&1; then
        info "Arquivo ZIP detectado. Extraindo..."
        unzip -q -o "$pacote" -d "$destino" >>"$LOG" 2>&1 || return 1
    elif tar -tf "$pacote" >/dev/null 2>&1; then
        info "Arquivo TAR detectado. Extraindo..."
        tar -xf "$pacote" -C "$destino" >>"$LOG" 2>&1 || return 1
    elif grep -qi '<html' "$pacote"; then
        info "Página HTML simples detectada."
        cp "$pacote" "$destino/index.html"
    else
        aviso "O arquivo baixado não é ZIP, TAR nem HTML."; return 1
    fi

    # Localiza o index.html mais próximo da raiz (templates costumam vir em subpastas)
    indice=$(find "$destino" -type f -iname 'index.html' -printf '%d\t%p\n' 2>/dev/null \
             | sort -n | head -n 1 | cut -f2)
    [[ -n $indice ]] || { aviso "Nenhum index.html encontrado no template."; return 1; }
    # Garante o nome em minúsculas (Index.html -> index.html)
    [[ $(basename "$indice") == "index.html" ]] || mv "$indice" "$(dirname "$indice")/index.html"
    DIR_TEMPLATE=$(dirname "$indice")
    return 0
}

# Página de contingência (usada apenas se nenhum template puder ser baixado)
gerar_pagina_contingencia() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="UTF-8"><title>${DOMINIO}</title>
<style>body{font-family:sans-serif;background:#0f172a;color:#e2e8f0;display:flex;
height:100vh;align-items:center;justify-content:center;margin:0}
.c{text-align:center}h1{font-size:3rem;margin:0}p{color:#94a3b8}</style></head>
<body><div class="c"><h1>${DOMINIO}</h1>
<p>Servidor ${WEB^^} + DNS BIND configurados automaticamente.</p>
<p>IP: ${IP_SERVIDOR}</p></div></body></html>
EOF
    DIR_TEMPLATE=$dir
}

publicar_template() {
    titulo "Download e publicação do template HTML"
    local tmp
    tmp=$(mktemp -d /tmp/template_XXXXXX)

    until baixar_template "$URL_TEMPLATE" "$tmp"; do
        if confirmar "Deseja informar outra URL de template?" s; then
            pedir_url_template
        else
            aviso "Será publicada uma página padrão gerada pelo script."
            gerar_pagina_contingencia "$tmp/contingencia"
            break
        fi
    done
    sucesso "Template pronto em: ${DIR_TEMPLATE}"

    info "Salvando backup do conteúdo atual de ${WEB_ROOT}..."
    mkdir -p "$WEB_ROOT"
    fazer_backup "$WEB_ROOT"

    info "Removendo a página padrão antiga e copiando o template para ${WEB_ROOT}..."
    find "$WEB_ROOT" -mindepth 1 -delete
    cp -a "${DIR_TEMPLATE}/." "$WEB_ROOT/"

    info "Ajustando dono (${WEB_USUARIO}) e permissões dos arquivos do site..."
    chown -R "${WEB_USUARIO}:${WEB_USUARIO}" "$WEB_ROOT"
    find "$WEB_ROOT" -type d -exec chmod 755 {} +
    find "$WEB_ROOT" -type f -exec chmod 644 {} +
    command -v restorecon >/dev/null && restorecon -R "$WEB_ROOT" >/dev/null 2>&1 || true

    rm -rf "$tmp"
    sucesso "Template publicado como página padrão ($(find "$WEB_ROOT" -type f | wc -l) arquivos)."
}

# ---------------------------------------------------------------------------
# ETAPA 7 - Firewall
# ---------------------------------------------------------------------------
configurar_firewall() {
    titulo "Liberação das portas no firewall (DNS 53, HTTP 80, HTTPS 443)"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        executar "Liberando porta 53 (DNS) no UFW..."     ufw allow 53
        executar "Liberando porta 80 (HTTP) no UFW..."    ufw allow 80/tcp
        executar "Liberando porta 443 (HTTPS) no UFW..."  ufw allow 443/tcp
        sucesso "Regras adicionadas ao UFW."
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        executar "Liberando serviços dns/http/https no firewalld..." \
            firewall-cmd --permanent --add-service=dns --add-service=http --add-service=https
        executar "Recarregando o firewalld..." firewall-cmd --reload
        sucesso "Regras adicionadas ao firewalld."
    else
        info "Nenhum firewall ativo (UFW/firewalld) detectado. Nada a fazer."
    fi
}

# ---------------------------------------------------------------------------
# ETAPA 8 - Resolvedor local (a própria máquina passa a usar este DNS)
# ---------------------------------------------------------------------------
configurar_resolver() {
    titulo "Configuração do resolvedor DNS local"
    if [[ $CONFIGURAR_RESOLVER != "s" ]]; then
        info "Etapa ignorada por escolha do usuário."
        return 0
    fi

    if tem_systemd && systemctl is-active --quiet systemd-resolved; then
        # systemd-resolved: envia somente as consultas do domínio para o BIND local
        local dominios="~${DOMINIO}"
        [[ $CRIAR_REVERSA == "s" ]] && dominios+=" ~${ZONA_REVERSA}"
        mkdir -p /etc/systemd/resolved.conf.d
        cat >/etc/systemd/resolved.conf.d/bind-local.conf <<EOF
# Gerado por instala_dns_web.sh
[Resolve]
DNS=127.0.0.1
Domains=${dominios}
EOF
        executar "Reiniciando o systemd-resolved..." systemctl restart systemd-resolved
        sucesso "Consultas para ${DOMINIO} agora são enviadas ao BIND local (127.0.0.1)."
    else
        fazer_backup /etc/resolv.conf
        if ! grep -q '^nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
            local original
            original=$(cat /etc/resolv.conf 2>/dev/null || true)
            # Escreve no próprio arquivo (preserva link simbólico, se houver)
            printf 'nameserver 127.0.0.1\n%s\n' "$original" >/etc/resolv.conf
        fi
        sucesso "127.0.0.1 adicionado como primeiro servidor DNS em /etc/resolv.conf."
    fi
}

# ---------------------------------------------------------------------------
# ETAPA 9 - Testes de validação
# ---------------------------------------------------------------------------
testar() {
    titulo "Testes de validação"
    local i nome tipo resposta falhas=0 codigo titulo_pagina

    info "Consultando cada registro no servidor DNS local (dig @127.0.0.1)..."
    resposta=$(dig +short @127.0.0.1 "$DOMINIO" NS 2>/dev/null || true)
    if [[ -n $resposta ]]; then sucesso "$(printf '%-30s %-6s -> %s' "$DOMINIO" NS "$resposta")"
    else aviso "$DOMINIO NS sem resposta"; falhas=$((falhas + 1)); fi

    for i in "${!REG_NOME[@]}"; do
        nome=$(fqdn "${REG_NOME[$i]}"); tipo=${REG_TIPO[$i]}
        resposta=$(dig +short @127.0.0.1 "$nome" "$tipo" 2>/dev/null | paste -sd ' ' - || true)
        if [[ -n $resposta ]]; then
            sucesso "$(printf '%-30s %-6s -> %s' "$nome" "$tipo" "$resposta")"
        else
            aviso "$(printf '%-30s %-6s -> sem resposta' "$nome" "$tipo")"; falhas=$((falhas + 1))
        fi
    done

    if [[ $CRIAR_REVERSA == "s" ]]; then
        resposta=$(dig +short @127.0.0.1 -x "$IP_SERVIDOR" 2>/dev/null | paste -sd ' ' - || true)
        if [[ -n $resposta ]]; then sucesso "Reverso de ${IP_SERVIDOR} -> ${resposta}"
        else aviso "Reverso de ${IP_SERVIDOR} sem resposta"; falhas=$((falhas + 1)); fi
    fi

    info "Testando o servidor Web (http://${DOMINIO})..."
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${DOMINIO}" http://127.0.0.1/ || true)
    titulo_pagina=$(curl -s --max-time 10 http://127.0.0.1/ | grep -oiP '(?<=<title>).*?(?=</title>)' | head -n 1 || true)
    if [[ $codigo == "200" ]]; then
        sucesso "Servidor Web respondeu HTTP 200. Título da página: \"${titulo_pagina:-sem título}\""
    else
        aviso "Servidor Web respondeu com código '${codigo}'."; falhas=$((falhas + 1))
    fi

    if [[ $CONFIGURAR_RESOLVER == "s" ]]; then
        if getent hosts "$DOMINIO" >/dev/null 2>&1; then
            sucesso "A própria máquina resolve ${DOMINIO} -> $(getent hosts "$DOMINIO" | awk '{print $1}' | head -n 1)"
        else
            aviso "A resolução local de ${DOMINIO} ainda não respondeu (teste com: dig ${DOMINIO})."
        fi
    fi

    if (( falhas == 0 )); then sucesso "Todos os testes passaram."
    else aviso "${falhas} teste(s) com problema. Consulte o log: ${LOG}"; fi
}

#==============================================================================
# 5. TAREFAS ADICIONAIS (DIA DA GLOBAL)
#    Para incluir uma nova tarefa:
#      1) crie uma função seguindo o modelo abaixo (use titulo/info/executar);
#      2) adicione o nome da função no vetor TAREFAS_EXTRAS.
#    Elas serão executadas automaticamente depois dos testes, com a mesma
#    numeração de etapas, log e tratamento de erros do restante do script.
#==============================================================================
TAREFAS_EXTRAS=(
    # tarefa_extra_1
    # tarefa_extra_2
    # tarefa_extra_3
)

# Modelo:
# tarefa_extra_1() {
#     titulo "Descrição da tarefa 1"
#     confirmar "Deseja executar a tarefa 1?" s || return 0
#     executar "Fazendo algo..." comando argumentos
#     sucesso "Tarefa 1 concluída."
# }

#==============================================================================
# 6. FLUXO PRINCIPAL
#==============================================================================
resumo_final() {
    local ip=$IP_SERVIDOR
    cat <<EOF

${VERDE}######################################################################
#                    INSTALAÇÃO CONCLUÍDA COM SUCESSO                #
######################################################################${RESET}

  ${NEGRITO}Site:${RESET}             http://${DOMINIO}  |  http://www.${DOMINIO}  |  http://${ip}
  ${NEGRITO}Servidor DNS:${RESET}     ${ip} (BIND - serviço '${BIND_SERVICO}')
  ${NEGRITO}Servidor Web:${RESET}     ${WEB^^} (serviço '${WEB_SERVICO}') - raiz: ${WEB_ROOT}
  ${NEGRITO}Arquivo de zona:${RESET}  ${BIND_DIR_ZONAS}/db.${DOMINIO}
  ${NEGRITO}Log completo:${RESET}     ${LOG}
  ${NEGRITO}Backups:${RESET}          ${DIR_BACKUP}

  Para acessar de outra máquina (ex.: VM cliente), configure o DNS dela
  para ${ip} e abra http://${DOMINIO} no navegador.

  Testes manuais úteis:
    dig @${ip} ${DOMINIO}
    nslookup www.${DOMINIO} ${ip}
    curl -I http://${DOMINIO}

EOF
}

main() {
    banner

    # O script altera configurações do sistema: exige root
    if [[ $EUID -ne 0 ]]; then
        erro "Este script precisa ser executado como root. Use: sudo $0"
        exit 1
    fi
    : >"$LOG"; chmod 600 "$LOG"
    log "Início da execução por ${SUDO_USER:-root} em $(hostname)"

    confirmar "Deseja continuar com a instalação?" n || { info "Nada foi alterado. Até logo!"; exit 0; }
    confirmar "Deseja confirmar cada etapa antes de executá-la (modo passo a passo)?" n \
        && MODO_PASSO_A_PASSO="s"

    TOTAL_ETAPAS=$(( 9 + ${#TAREFAS_EXTRAS[@]} ))

    verificar_ambiente     # Etapa 1
    etapa_coleta           # Etapa 2
    instalar_pacotes       # Etapa 3
    configurar_bind        # Etapa 4
    configurar_web         # Etapa 5
    publicar_template      # Etapa 6
    configurar_firewall    # Etapa 7
    configurar_resolver    # Etapa 8
    testar                 # Etapa 9

    local tarefa
    for tarefa in "${TAREFAS_EXTRAS[@]}"; do
        "$tarefa"
    done

    resumo_final
    log "Fim da execução."
}

main "$@"
