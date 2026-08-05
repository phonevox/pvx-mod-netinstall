#!/usr/bin/env bash
# modules/netinstall/lib/common.sh — hardening e utilidades compartilhadas entre issabel4.sh e
# issabel5.sh. Exclusivo deste módulo: não é lib compartilhada do pvx-core (ver
# docs/module-authoring.md §3) — só usa o que já vem via `pvx::require` (color/log/os/exec/tui/net).

NETINSTALL_MIRROR_PROBE_URL=${NETINSTALL_MIRROR_PROBE_URL:-http://mirror.issabel.org}
NETINSTALL_FORCE=${NETINSTALL_FORCE:-0}
NETINSTALL_NO_TMUX=${NETINSTALL_NO_TMUX:-0}
# RAM+swap mínimo (KB) pra tentar a instalação: abaixo disso o risco de OOM-killer matar o
# `dnf install` (e o próprio pvx junto) no meio da transação é alto o bastante pra avisar
# ANTES de começar, não deixar o operador descobrir pela morte súbita e muda do processo.
NETINSTALL_MIN_MEM_KB=${NETINSTALL_MIN_MEM_KB:-$((1536 * 1024))}
# Chave pública SSH principal da Phonevox — default do usuário dedicado da tweak
# ssh-hardening. Ninguém precisa pensar em qual chave colar; só confirmar (Enter) ou trocar.
NETINSTALL_SSH_DEFAULT_PUBKEY=${NETINSTALL_SSH_DEFAULT_PUBKEY:-'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC5S9t+CHuQYVe9It/zVWNEYWq7fuGBF1oll63MujAREeP3sB3NVhrWs8AcDNOwPQ+8Z7s4Yc8/r8BKCquujugkWv3ilZjJAbeyR7A6rddRM1ai1bfc8gRV7CD1tExQuO+QE9RORQ0f0J+0+Fu4vB3YRMeSx4czq5tbYKwvdfP6pgWWRppyA8uM7nKXnYsdwkyKxJZb4I353cC4C+ZvaEUQahygNs9XgblBB9TM0UuttdoBi4pTj4aqLXTBhcLqghkQP45JaQ8/G5qSzs2U2eGH4L+mEqFSg+ybL3KxGmyHxtCBOqhFTm/s3EqkSQ80OSwdYSzH7GMTWWfKZ4UoeFiQucHYto83LmfBYdqckbtw7ZNsXU/egQR5eSwtwQBK5yLnPSnQldozMKoS2gKayWtxqvjiYpQacw48DaB1mZUfl7SJ/fa9LEUrQ2CnizQJSemwsteJqDII95mzCpyGXAeNfXdhI52dx0YXx3D62LXQBAn1HSIgnzsrEVh29CumZ28cxpOL0djI2Y8VyHgw6fFSAZqmn3Xr2yCxBvzN4rlEvtzGVw8PxAZT33duLEgPFV2XBrU5I98bufgg8cE3NXTLtMwuYWbtKtbRZkpRJesQEkaL70kLvvsYCZAaqDhwLAO8q41czunYLt6MyKcAHrb5whFBz6Fx/WrEEpM1p5KhSw== MAIN@PHONEVOX'}

# netinstall::_mem_total_kb [arquivo] — soma MemTotal+SwapTotal (KB) de /proc/meminfo (ou de
# um arquivo no mesmo formato, pra teste). Soma o TOTAL de swap, não o livre: swap alocável é
# o que importa pro risco de OOM, já usado ou não no momento da checagem. Devolve 0 (não
# bloqueia nada) se o arquivo não existir/não puder ser lido — ex: dentro de alguns
# containers /proc/meminfo reflete o host e não o cgroup, mas preferimos otimista a bloquear
# por um sinal que pode nem ser real ali dentro.
netinstall::_mem_total_kb() {
  local file=${1:-/proc/meminfo}
  local mem_total=0 swap_total=0 k v
  [[ -r $file ]] || { printf '0'; return 0; }
  while read -r k v _; do
    case $k in
      MemTotal:) mem_total=$v ;;
      SwapTotal:) swap_total=$v ;;
    esac
  done <"$file"
  printf '%s' "$((mem_total + swap_total))"
}

# netinstall::preflight <produto> <min_version> — bloqueia cedo em vez de deixar o `dnf/yum
# install` de centenas de pacotes falhar 20 minutos depois. Cada checagem já loga o motivo
# específico antes de sair.
#
# <min_version> é OBRIGATÓRIO (sem default) de propósito: issabel4 (CentOS 7, yum, sem
# módulos dnf) e issabel5 (Rocky/RHEL 8+, dnf, módulo php:remi-7.4) têm alvos de SO
# DIFERENTES — um valor hardcoded aqui (achado de verdade: era "8" fixo pros dois) bloqueava o
# issabel4 pra sempre no PRÓPRIO SO alvo dele ("requer versão >= 8, detectado 7"), já que
# ninguém nunca chega a rodar isto numa CentOS 8+ de verdade (o port dele nunca foi adaptado
# pra AppStream/módulos — teria os mesmos "No match for argument" do issabel5, só que sem o
# equivalente ao centos8_tweaks). Cada produto passa o próprio mínimo (ver
# netinstall::run_issabel4/_issabel5_raw/_issabel5_custom).
netinstall::preflight() {
  local produto=$1 min_version=${2:?netinstall::preflight: min_version não informado}

  os::require_root "netinstall $produto"

  os::require_rhel_like "netinstall $produto" || exit "$PVX_EXIT_UNSUPPORTED"
  os::require_min_version "$min_version" "netinstall $produto" || exit "$PVX_EXIT_UNSUPPORTED"

  if os::is_container; then
    log::warn 'netinstall: rodando dentro de um container (%s) — systemd/firewalld/reboot podem se comportar de forma diferente de uma máquina real' \
      "$(os::pretty)"
  fi

  # Só avisa (não bloqueia, não pede --force): RAM+swap baixa é um risco real pra instalação de
  # LAMP+Asterisk completos, mas não é o suficiente pra travar quem sabe o que está fazendo —
  # e o operador já vê o resto do processo (spinner + "comando falhou" de verdade agora, ver
  # lib/exec.sh) se algo realmente der errado no meio do caminho.
  local mem_total_kb
  mem_total_kb=$(netinstall::_mem_total_kb)
  if ((mem_total_kb > 0 && mem_total_kb < NETINSTALL_MIN_MEM_KB)); then
    log::warn 'netinstall %s: RAM+swap baixa (%d MB, recomendado >= %d MB)' \
      "$produto" "$((mem_total_kb / 1024))" "$((NETINSTALL_MIN_MEM_KB / 1024))"
    log::hint 'crie um swapfile: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile'
  fi

  local existing_issabel existing_asterisk
  existing_issabel=$(os::issabel_version 2>/dev/null) || existing_issabel=''
  existing_asterisk=$(os::asterisk_version 2>/dev/null) || existing_asterisk=''
  if [[ -n $existing_issabel || -n $existing_asterisk ]]; then
    log::warn 'netinstall: esta máquina já parece ter Issabel (%s) / Asterisk (%s) instalado' \
      "${existing_issabel:-?}" "${existing_asterisk:-?}"
    if (( ! NETINSTALL_FORCE )); then
      log::error 'netinstall: recusando reinstalar por cima de uma central que já parece ativa'
      log::hint 'use --force se tem certeza que quer continuar mesmo assim'
      exit "$PVX_EXIT_PRECONDITION"
    fi
    log::warn 'netinstall: continuando por causa de --force'
  fi

  if net::is_offline; then
    log::error 'netinstall: sem acesso de rede (PVX_OFFLINE=1 ou curl ausente) — impossível baixar pacotes/repositórios'
    exit "$PVX_EXIT_UNAVAILABLE"
  fi
  local probe_rc=0
  # --connect-timeout 10 (não 5) e --retry 2: achado de verdade numa VPS de rede lenta/instável
  # onde esse mesmo host respondia bem a um curl sem timeout customizado (ou a um `ping`), mas
  # dava rc=28 aqui — o timeout curto é que estava curto demais, não necessariamente firewall.
  curl -fsS --connect-timeout 10 --max-time 15 --retry 2 --retry-delay 2 --retry-connrefused \
    -o /dev/null "$NETINSTALL_MIRROR_PROBE_URL" 2>/dev/null || probe_rc=$?
  if ((probe_rc != 0)); then
    # dnf/yum vão bater nesse mesmo mirror via http:// mais adiante (ver config/repos*/*.repo) —
    # se a checagem falha aqui, a instalação de pacotes de verdade ia falhar do mesmo jeito lá
    # na frente, só que 15-20 minutos depois. Traduz o rc do curl pra apontar a causa provável
    # em vez de um "confira a rede" genérico — sem afirmar categoricamente "é firewall" pro
    # rc=28, já que pode ser só rede lenta (mesmo achado acima).
    local motivo='motivo desconhecido'
    case $probe_rc in
      6) motivo='DNS não resolveu o host' ;;
      7) motivo='conexão recusada — nada escutando ou bloqueado antes de chegar no host' ;;
      28) motivo='timeout de conexão mesmo após retry — pode ser porta bloqueada por firewall OU rede lenta/instável' ;;
      22 | 35 | 60) motivo='servidor respondeu, mas com erro HTTP/TLS' ;;
    esac
    log::error 'netinstall: não foi possível alcançar %s (curl rc=%d: %s)' \
      "$NETINSTALL_MIRROR_PROBE_URL" "$probe_rc" "$motivo"
    exit "$PVX_EXIT_UNAVAILABLE"
  fi

  # tmux NÃO entra aqui de propósito: netinstall::ensure_tmux já trata a ausência dele como
  # best-effort (avisa e segue sem sessão persistente) — exigir aqui também contradiria isso e
  # travava a instalação inteira por falta de um pacote que é só uma melhoria de robustez,
  # não um requisito real. Achado de verdade: o aviso de "continuando sem tmux" aparecia e,
  # duas linhas depois, o preflight abortava mesmo assim.
  exec::require_cmd rpm curl || exit "$PVX_EXIT_UNAVAILABLE"
  return 0
}

# netinstall::ensure_tmux <produto> "$@" — se já estamos dentro de uma sessão tmux, ou --no-tmux
# foi passado (varre os args recebidos, de propósito: chamado ANTES do flag::parse "de
# verdade", pra decidir isso sem duplicar validação de flag), não faz nada. Senão, relança a
# própria invocação dentro de uma sessão nova e sai — sobrevive a queda de SSH sem depender do
# operador lembrar de abrir tmux manualmente antes (era instrução manual no README do pissabel5).
#
# Com --debug/-v/--verbose/--trace (varrido aqui pelos mesmos tokens crus que bin/pvx reconhece,
# ver lib/flags.sh e bin/pvx), a sessão NUNCA fecha sozinha, mesmo depois do comando terminar
# (sucesso, erro, ou crash) — fica lá com "Pane is dead" até o próprio sysadmin encerrar (`tmux
# kill-session -t <sessão>`). Achado de verdade: em modo debug o operador quer poder rolar pra
# trás e ler tudo com calma; por padrão, tmux fecha a janela assim que o comando dentro dela sai,
# derrubando a sessão (e o scrollback) antes de dar tempo de olhar. `remain-on-exit` resolve isso
# sem precisar mudar como o comando roda (nada de exec'ar um shell novo por cima) — só cria a
# sessão destacada, liga a opção, e só então anexa.
netinstall::ensure_tmux() {
  local produto=$1
  shift
  [[ -n ${TMUX:-} ]] && return 0
  local a keep_alive=0
  for a in "$@"; do
    case $a in
      --no-tmux | -h | --help) return 0 ;;
      -v | --verbose | --debug | --trace | --log-level=debug | --log-level=trace) keep_alive=1 ;;
    esac
  done
  if ! command -v tmux >/dev/null 2>&1; then
    log::warn 'netinstall: tmux não encontrado — continuando sem sessão persistente (instale tmux ou use --no-tmux pra silenciar este aviso)'
    return 0
  fi

  local session="pvx-netinstall-$produto"
  log::info 'netinstall: iniciando dentro de uma sessão tmux (%s); use --no-tmux pra desligar isso' \
    "$session"
  if (( keep_alive )); then
    log::info 'netinstall: modo debug/verbose — a sessão tmux (%s) não fecha sozinha; encerre com "tmux kill-session -t %s" quando terminar' \
      "$session" "$session"
    exec tmux new-session -d -s "$session" -- "$0" "$produto" "$@" \; \
      set-option -t "$session" remain-on-exit on \; \
      attach-session -t "$session"
  fi
  exec tmux new-session -s "$session" -- "$0" "$produto" "$@"
}

# netinstall::ask_password <título> <rótulo> — prompt mascarado (sem eco, igual a um `sudo`);
# enter vazio (ou sem TTY nenhum) gera uma senha aleatória em vez de aceitar "" como senha de
# verdade — nunca trava esperando teclado fora de terminal interativo. A exibição em si
# (título/breadcrumb + rótulo + leitura mascarada) é toda de tui::password (lib/tui.sh) — pra
# ficar visualmente igual ao resto dos prompts do menu (mesmo cabeçalho de tui::select/
# checklist), em vez de desenhar um estilo próprio aqui. Achado de verdade corrigido nessa
# unificação: a versão antiga usava `read -rsp ... 2>/dev/null` (mesmo anti-padrão já
# documentado em exec::confirm — o `-p` escreve em stderr, e o `2>/dev/null` engolia o prompt
# inteiro) e o operador tinha que apertar enter às cegas pra passar pelo prompt invisível.
netinstall::ask_password() {
  local title=$1 label=$2
  tui::password "$title" "$label [aleatório]"
  local v=$TUI_PASSWORD
  [[ -z $v ]] && v=$(netinstall::gen_password)
  printf '%s' "$v"
}

# netinstall::resolve_secret_or_ask <flag> <título> <rótulo> — usa o valor já resolvido por
# --<flag>/--<flag>-file/variável de ambiente se qualquer um desses foi dado (mesma prioridade
# de flag::_resolve_secret); só cai em netinstall::ask_password se nenhum dos três veio —
# assim a pergunta usa nosso texto (com "gera aleatória" explícito) em vez do prompt genérico
# de lib/flags.sh, sem duplicar a lógica de resolução de --flag/--flag-file/env.
netinstall::resolve_secret_or_ask() {
  local long=$1 title=$2 label=$3 env
  if flag::has "$long" || flag::has "$long-file"; then
    flag::get "$long"
    return 0
  fi
  env=${PVX_FLAG_ENV[$long]:-}
  if [[ -n $env && -n ${!env:-} ]]; then
    flag::get "$long"
    return 0
  fi
  netinstall::ask_password "$title" "$label"
}

# netinstall::print_summary <produto> <astver> <addpkgs_display> — resumo do que foi escolhido
# (flag ou interativo), impresso ANTES da confirmação destrutiva. Achado de verdade: um
# "Prosseguir com a instalação?" solto, sem mostrar com o que exatamente, obriga o operador a
# confiar de memória no que respondeu — metade das respostas (astver, addpkgs) já rolou pra
# fora da tela ou veio só de flag, nunca visível junto. Vai pra stderr (igual ao resto dos
# prompts do menu), não por log:: — é uma tela de revisão, não um evento de log.
# netinstall::_summary_section <rótulo> — separador visível entre grupos do resumo (Sistema /
# Tweaks Phonevox / SSH Hardening etc.), cor moderada (cyan, mesma família do destaque de
# tui::breadcrumb) — só o rótulo do separador, não os valores abaixo dele.
netinstall::_summary_section() {
  printf '\n  %s── %s ──%s\n' "${PVX_C[cyan]:-}" "$1" "${PVX_C[reset]:-}" >&2
}

netinstall::print_summary() {
  local produto=$1 astver=$2 addpkgs_display=$3 tweaks_display=${4:-nenhum} extra=${5:-}
  local tz lang
  tz=$(flag::get timezone 'America/Sao_Paulo')
  lang=$(flag::get lang pt_BR)
  printf '\n%s%s%s\n' "${PVX_C[bold]:-}" "$(tui::breadcrumb netinstall "$produto" 'resumo')" "${PVX_C[reset]:-}" >&2
  netinstall::_summary_section Sistema
  printf '  Asterisk: %s\n' "$astver" >&2
  printf '  Pacotes extras: %s\n' "$addpkgs_display" >&2
  printf '  Timezone: %s\n' "$tz" >&2
  printf '  Idioma: %s\n' "$lang" >&2
  printf '  Senhas (MySQL/Web): definidas\n' >&2
  netinstall::_summary_section 'Tweaks Phonevox'
  printf '  %s\n' "$tweaks_display" >&2
  [[ -n $extra ]] && printf '%s\n' "$extra" >&2
  printf '\n' >&2
}

# netinstall::_tweaks_catalog — catálogo de tweaks Phonevox conhecidos, um por linha, campos
# separados por TAB: chave / produto(s) aplicável(is) ("all" ou lista separada por vírgula,
# ex. "issabel5") / default 0|1 (pré-marcado na checklist e usado como fallback sem TTY/flag) /
# rótulo exibido. Adicionar tweak novo é UMA linha aqui — ver docs/netinstall-phonevox-tweaks-spec.md.
netinstall::_tweaks_catalog() {
  cat <<'EOF'
operator-panel	issabel5	1	Painel do operador (control_panel — visão de recepção/switchboard)
ssh-hardening	issabel5	1	Hardening de acesso SSH (bloqueia root, cria usuário admin dedicado, muda porta)
EOF
}

# netinstall::phonevox_tweaks_menu <produto> <has_tty> — resolve as tweaks Phonevox aplicáveis
# a <produto> (filtra o catálogo acima) e POPULA a array `tweaks` (já declarada pelo chamador,
# ex. `local -a tweaks=()`) com as chaves escolhidas. Mesmo contrato de flag::has/--*-file/TTY
# já usado pro resto do netinstall (ver netinstall::flags_shared): `--tweaks <chave>` dado
# (repetível) manda, sem perguntar nada; sem flag e com TTY, mostra a checklist (pré-marcada
# conforme a coluna default do catálogo); sem flag e sem TTY, cai pros defaults do catálogo
# (NÃO "nenhum" — ao contrário de addpkgs, aqui um tweak pode já ter sido comportamento padrão
# de sempre, ex. operator-panel; um default silencioso "nenhum" seria regressão pra quem
# automatiza sem passar --tweaks). Produto sem nenhum tweak aplicável (ex. issabel4 hoje) não
# mostra checklist nenhuma — só deixa `tweaks` vazia.
#
# NUNCA chame isto via `$(...)`/`< <(...)` — nem pra ler `tweaks`, nem pra propagar o `exit`
# de chave desconhecida. Dois achados de verdade, os dois por causa de rodar numa subshell:
#   1) `<has_tty>` tem que vir JÁ resolvido pelo chamador (`[[ -t 0 && -t 1 ]]` de FORA desta
#      função) — um `-t 1` checado aqui dentro, se a função rodasse via `$(...)`, sempre daria
#      falso (fd 1 vira o pipe da captura, não o terminal de verdade), fazendo a checklist
#      nunca aparecer.
#   2) `tui::checklist` escreve PARTE da própria UI em stdout, não só stderr (título, itens,
#      rodapé — ver lib/tui.sh:333-345) — capturar a função via `$(...)` also captura esse
#      texto, embaralhando tudo junto com as chaves escolhidas (visto de verdade: o resumo
#      saía com a tela inteira da checklist grudada na linha "Tweaks Phonevox: ...").
# É por isso que a função escreve direto na array do chamador (mesmo truque de escopo dinâmico
# de core::_menu_build_options em bin/pvx) em vez de imprimir e deixar o chamador capturar —
# roda no MESMO processo/terminal do resto do netinstall, igual astver/addpkgs já fazem.
netinstall::phonevox_tweaks_menu() {
  local produto=$1 has_tty=$2
  local -a keys=() labels=() defaults=()
  local key produtos default_on label

  tweaks=()

  while IFS=$'\t' read -r key produtos default_on label; do
    [[ -z $key ]] && continue
    if [[ $produtos != all ]]; then
      local -a plist=()
      local p match=0
      IFS=',' read -r -a plist <<<"$produtos"
      for p in "${plist[@]}"; do
        [[ $p == "$produto" ]] && {
          match=1
          break
        }
      done
      ((match)) || continue
    fi
    keys+=("$key")
    labels+=("$label")
    defaults+=("$default_on")
  done < <(netinstall::_tweaks_catalog)

  if flag::has tweaks; then
    local -a given=()
    IFS=$'\x1f' read -r -a given <<<"${PVX_FLAG_MULTI[tweaks]:-${PVX_FLAG_VALUE[tweaks]:-}}"
    local g i found
    for g in ${given[@]+"${given[@]}"}; do
      found=0
      for ((i = 0; i < ${#keys[@]}; i++)); do
        [[ ${keys[i]} == "$g" ]] && {
          found=1
          break
        }
      done
      if ((!found)); then
        log::error 'netinstall: tweak desconhecida (ou não aplicável a %s): %s' "$produto" "$g"
        exit "$PVX_EXIT_USAGE"
      fi
      tweaks+=("$g")
    done
  elif ((has_tty)) && ((${#keys[@]})); then
    local -a items=() item
    local i
    TUI_CHECKLIST_DEFAULT=()
    for ((i = 0; i < ${#keys[@]}; i++)); do
      items+=("$(printf '%-16s %s' "${keys[i]}" "${labels[i]}")")
      TUI_CHECKLIST_DEFAULT+=("${defaults[i]}")
    done
    tui::checklist "$(tui::with_desc "$(tui::breadcrumb netinstall "$produto" 'Tweaks Phonevox')" \
      'Customizações Phonevox opcionais, aplicadas depois da instalação principal.')" "${items[@]}"
    for item in ${TUI_RESULT[@]+"${TUI_RESULT[@]}"}; do
      tweaks+=("${item%% *}")
    done
  else
    local i
    for ((i = 0; i < ${#keys[@]}; i++)); do
      ((defaults[i])) && tweaks+=("${keys[i]}")
    done
  fi
}

# netinstall::gen_password — senha aleatória por instalação (nunca um default fixo
# hardcoded/compartilhado entre máquinas, ao contrário do legado).
netinstall::gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '=+/\n' | cut -c1-24
    return 0
  fi
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24
  printf '\n'
}

# netinstall::ssh_validate_pubkey <linha> — só valida o FORMATO (tipo + base64 + comentário
# opcional), não a chave em si.
netinstall::ssh_validate_pubkey() {
  local line=$1
  [[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# netinstall::sshd_config_upsert <arquivo> <diretiva> <valor> — garante uma linha canônica
# "<diretiva> <valor>" no final do arquivo (sshd respeita a última ocorrência ativa);
# idempotente, comenta qualquer ocorrência ativa anterior em vez de apagar.
netinstall::sshd_config_upsert() {
  local file=$1 directive=$2 value=$3
  [[ -w $file ]] || return 1

  local last_active
  # `|| true`: grep sem match (diretiva ainda não existe ativa — caso comum) sai com rc=1, que
  # sob `set -e`+`pipefail` mataria o script inteiro numa simples atribuição de variável.
  last_active=$(grep -E "^[[:space:]]*${directive}[[:space:]]" "$file" | tail -n1) || true
  [[ $last_active == "$directive $value" ]] && return 0

  sed -i -E "s/^([[:space:]]*)(${directive}[[:space:]].*)/\1# disabled by pvx netinstall ssh-hardening: \2/" "$file"
  printf '%s %s\n' "$directive" "$value" >>"$file"
}

# netinstall::save_credentials <produto> <sql_password> <web_password> — grava uma única vez
# em $PVX_MODULE_STATE_DIR (0600) e devolve o caminho — é a única cópia recuperável depois que
# a tela rolar.
netinstall::save_credentials() {
  local produto=$1 sql_pw=$2 web_pw=$3
  shift 3
  local -a extra=("$@")
  local dir file ts kv
  dir=${PVX_MODULE_STATE_DIR:?PVX_MODULE_STATE_DIR não definido}
  mkdir -p "$dir"
  printf -v ts '%(%Y%m%dT%H%M%S)T' -1
  file="$dir/credentials-$produto-$ts.txt"
  {
    printf 'produto=%s\n' "$produto"
    printf 'data=%s\n' "$ts"
    printf 'mysql_root_password=%s\n' "$sql_pw"
    printf 'web_admin_password=%s\n' "$web_pw"
    for kv in ${extra[@]+"${extra[@]}"}; do
      printf '%s\n' "$kv"
    done
  } >"$file"
  chmod 0600 "$file"
  printf '%s' "$file"
}

# netinstall::confirm_destructive <mensagem> — gate antes de SELinux/firewalld off + reboot
# final. Ao contrário do legado (nunca perguntava nada aqui), falha FECHADO sem TTY e sem
# --yes: nunca reinicia um servidor sozinho sem ninguém ter autorizado explicitamente.
netinstall::confirm_destructive() {
  local msg=$1
  exec::confirm "$msg [s/N]" n
}

# netinstall::install_packages <rótulo> <pacote...> — tenta a lista inteira num único `dnf
# install` (rápido: paga o custo de metadata/sack dos repos uma vez só). Se a transação em
# lote falhar — típico quando um nome de pacote não existe mais no repo (renomeado/removido
# entre releases) — cai pra instalação pacote a pacote, pra isolar só o(s) problemático(s) em
# vez de perder a lista inteira por causa de um nome só. Nunca aborta o processo: reporta os
# que falharam e segue em frente, quem decide o que fazer com isso é o operador.
netinstall::install_packages() {
  local label=$1
  shift
  local -a pkgs=("$@")
  ((${#pkgs[@]} == 0)) && return 0
  log::info 'netinstall: instalando %s (%d pacotes)...' "$label" "${#pkgs[@]}"
  os::pkg_install "${pkgs[@]}" && return 0

  log::warn 'netinstall: instalação em lote de "%s" falhou, tentando pacote por pacote' "$label"
  local -a failed=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    os::pkg_install "$pkg" || failed+=("$pkg")
  done
  if ((${#failed[@]})); then
    log::error 'netinstall: %d de %d pacotes de "%s" não instalados: %s' \
      "${#failed[@]}" "${#pkgs[@]}" "$label" "${failed[*]}"
  fi
  return 0
}

# netinstall::flags_shared — flags comuns a `issabel4`/`issabel5`. Cada produto ainda declara
# a própria `--astver` (enum diferente por versão suportada) depois de chamar isto.
#
# Contrato único, sem modo "interativo vs upfront" separado: pra cada informação (astver,
# addpkgs, senha, ...), se a flag correspondente foi dada, usa ela e não pergunta nada; se
# faltou e tem TTY, pergunta SÓ aquela informação (nunca um wizard de tudo de uma vez, nunca
# tudo intercalado igual o legado); sem TTY e sem flag, erro claro do que falta. Senhas usam
# netinstall::resolve_secret_or_ask (flag/--*-file/env têm prioridade; só cai no prompt
# próprio se nenhum dos três veio).
netinstall::flags_shared() {
  flag::add lang --default pt_BR --help 'idioma do sistema/Issabel'
  flag::add timezone --default 'America/Sao_Paulo' --help 'timezone do sistema e do PHP'
  flag::add addpkgs --repeat --help 'pacote adicional a instalar (pode repetir a flag)'
  flag::add tweaks --repeat --help 'tweak Phonevox a habilitar após a instalação (pode repetir a flag; ver --help pra lista)'
  # nomes positivos de propósito: "--no-X" já é sintaxe nativa do lib/flags.sh pra negar um
  # bool chamado "X" (flag::parse trata qualquer token "--no-*" assim) — declarar um flag
  # literalmente chamado "no-tmux" colide com isso (`--no-tmux` seria lido como "negar um flag
  # chamado tmux", que não existiria, e falharia como opção desconhecida).
  flag::add tmux --type bool --default 1 --help 'usa uma sessão tmux persistente (desligue com --no-tmux)'
  flag::add reboot --type bool --default 1 --help 'reinicia o servidor ao final (desligue com --no-reboot)'
  flag::add force --type bool --help 'ignora a checagem de "já parece instalado"'
  flag::add_secret sql-password --prompt 'senha root do MySQL desta instalação'
  flag::add_secret web-password --prompt 'senha admin da interface Web do Issabel'
}

# netinstall::ssh_hardening_flags — registra as flags headless da tweak ssh-hardening. Chame
# ANTES de flag::parse, junto do resto das flags do produto.
netinstall::ssh_hardening_flags() {
  flag::add tweak-ssh-lock-root --type bool --default 1 \
    --help 'ssh-hardening: desabilita login SSH do root e padroniza sua senha'
  flag::add_secret tweak-ssh-root-password \
    --prompt 'senha do root pra acesso via KVM/console (vazio = phonevox@@)'
  flag::add tweak-ssh-create-user --type bool --default 1 \
    --help 'ssh-hardening: cria um usuário dedicado com sudo'
  flag::add tweak-ssh-username --default phonevox \
    --help 'ssh-hardening: nome do usuário dedicado'
  flag::add tweak-ssh-pubkey --default "$NETINSTALL_SSH_DEFAULT_PUBKEY" \
    --help 'ssh-hardening: chave pública SSH autorizada pro usuário dedicado (default: chave principal da Phonevox)'
  flag::add tweak-ssh-allow-password --type bool --default 0 \
    --help 'ssh-hardening: permite login por senha (além da chave) pro usuário dedicado'
  flag::add tweak-ssh-change-port --type bool --default 1 \
    --help 'ssh-hardening: troca a porta padrão do SSH'
  flag::add tweak-ssh-port --default 21122 \
    --help 'ssh-hardening: nova porta SSH'
}

# netinstall::ssh_hardening_ask <has_tty> — popula SSH_HARDEN_* no escopo do chamador (mesmo
# idioma de `tweaks`/phonevox_tweaks_menu). Chame direto, nunca via $(...): tui::select/input
# escrevem parte da UI em stdout.
netinstall::ssh_hardening_ask() {
  local has_tty=$1

  SSH_HARDEN_LOCK_ROOT=0
  SSH_HARDEN_ROOT_PASSWORD=''
  SSH_HARDEN_CREATE_USER=0
  SSH_HARDEN_USERNAME=''
  SSH_HARDEN_PUBKEY=''
  SSH_HARDEN_ALLOW_PASSWORD=0
  SSH_HARDEN_USER_PASSWORD=''
  SSH_HARDEN_CHANGE_PORT=0
  SSH_HARDEN_PORT=''

  # Sem TTY e sem NENHUMA flag --tweak-ssh-*: não aplica nada (não herda o default do catálogo
  # em automação que não conhece esta flag).
  if ((!has_tty)); then
    local f any_flag=0
    for f in tweak-ssh-lock-root tweak-ssh-root-password tweak-ssh-root-password-file \
      tweak-ssh-create-user tweak-ssh-username tweak-ssh-pubkey \
      tweak-ssh-allow-password tweak-ssh-change-port tweak-ssh-port; do
      flag::has "$f" && { any_flag=1; break; }
    done
    ((any_flag)) || return 0
  fi

  # Atalho: com TTY, pergunta UMA vez se quer os padrões da Phonevox de cara (sem repetir as 6
  # perguntas seguintes, cada uma na sua tela) ou revisar item por item (fluxo de sempre). Só
  # entra em jogo quando NÃO há flag pro item específico — uma flag explícita (`elif
  # flag::has ...` em cada bloco abaixo) sempre vence, quick ou não.
  local quick=0
  if ((has_tty)); then
    tui::select "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH')" \
      'Como configurar o hardening de SSH?')" \
      'Usar padrões da Phonevox (recomendado)' 'Personalizar cada opção' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Usar padrões da Phonevox (recomendado)' ]] && quick=1
  fi

  # 1. bloquear root
  if flag::has tweak-ssh-lock-root; then
    SSH_HARDEN_LOCK_ROOT=$(flag::get tweak-ssh-lock-root 1)
  elif ((has_tty)) && ((!quick)); then
    tui::select "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'bloquear root')" \
      'Desabilita o login SSH do root e padroniza sua senha (uso restrito a KVM/console).')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_LOCK_ROOT=1
  else
    SSH_HARDEN_LOCK_ROOT=1
  fi

  if ((SSH_HARDEN_LOCK_ROOT)); then
    if flag::has tweak-ssh-root-password || flag::has tweak-ssh-root-password-file; then
      SSH_HARDEN_ROOT_PASSWORD=$(flag::get tweak-ssh-root-password)
      [[ -z $SSH_HARDEN_ROOT_PASSWORD ]] && SSH_HARDEN_ROOT_PASSWORD='phonevox@@'
    elif ((has_tty)) && ((!quick)); then
      tui::password "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'senha do root')" \
        'Usada só via KVM/console — o root não aceita mais login SSH.')" \
        'senha do root [phonevox@@]'
      SSH_HARDEN_ROOT_PASSWORD=${TUI_PASSWORD:-phonevox@@}
    else
      SSH_HARDEN_ROOT_PASSWORD='phonevox@@'
    fi
    log::add_secret "$SSH_HARDEN_ROOT_PASSWORD"
  fi

  # 2. usuário dedicado
  if flag::has tweak-ssh-create-user; then
    SSH_HARDEN_CREATE_USER=$(flag::get tweak-ssh-create-user 1)
  elif ((has_tty)) && ((!quick)); then
    tui::select "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'usuário dedicado')" \
      'Cria uma conta com sudo (grupo wheel), autenticada por chave SSH.')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_CREATE_USER=1
  else
    SSH_HARDEN_CREATE_USER=1
  fi

  if ((SSH_HARDEN_CREATE_USER)); then
    SSH_HARDEN_USERNAME=$(flag::get tweak-ssh-username phonevox)
    if ((has_tty)) && ((!quick)) && ! flag::has tweak-ssh-username; then
      tui::input 'nome do usuário dedicado' phonevox \
        "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'usuário dedicado' 'nome')" \
          'Nome da conta criada com sudo.')" \
        || exit "$PVX_EXIT_ABORTED"
      SSH_HARDEN_USERNAME=$TUI_INPUT
    fi
    if [[ ! $SSH_HARDEN_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      log::error 'netinstall issabel5: --tweak-ssh-username inválido (use [a-z0-9_-], começando com letra/underscore): %s' "$SSH_HARDEN_USERNAME"
      exit "$PVX_EXIT_USAGE"
    fi

    # Default = chave principal da Phonevox (NETINSTALL_SSH_DEFAULT_PUBKEY), tanto na flag
    # (--tweak-ssh-pubkey já sai com --default) quanto aqui no TTY — ninguém precisa ir buscar
    # a própria chave, só confirmar (Enter) ou colar outra se quiser.
    if flag::has tweak-ssh-pubkey; then
      SSH_HARDEN_PUBKEY=$(flag::get tweak-ssh-pubkey)
      if ! netinstall::ssh_validate_pubkey "$SSH_HARDEN_PUBKEY"; then
        log::error 'netinstall issabel5: --tweak-ssh-pubkey não parece uma chave pública SSH válida'
        exit "$PVX_EXIT_USAGE"
      fi
    elif ((has_tty)) && ((!quick)); then
      while true; do
        tui::input 'cole a chave pública SSH (ssh-ed25519/ssh-rsa/ecdsa-sha2-*)' \
          "$NETINSTALL_SSH_DEFAULT_PUBKEY" \
          "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'usuário dedicado' 'chave pública')" \
            'Chave autorizada nessa conta — Enter usa a chave principal da Phonevox.')" \
          || exit "$PVX_EXIT_ABORTED"
        netinstall::ssh_validate_pubkey "$TUI_INPUT" && { SSH_HARDEN_PUBKEY=$TUI_INPUT; break; }
        printf 'chave inválida — precisa começar com ssh-ed25519/ssh-rsa/ecdsa-sha2-*\n' >&2
      done
    else
      SSH_HARDEN_PUBKEY=$NETINSTALL_SSH_DEFAULT_PUBKEY
    fi

    if flag::has tweak-ssh-allow-password; then
      SSH_HARDEN_ALLOW_PASSWORD=$(flag::get tweak-ssh-allow-password 0)
    elif ((has_tty)) && ((!quick)); then
      tui::select "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'permitir senha')" \
        'Para o usuário dedicado, deseja permitir login via senha?')" \
        'Não (recomendado, só chave)' 'Sim' || exit "$PVX_EXIT_ABORTED"
      [[ $TUI_CHOICE == 'Sim' ]] && SSH_HARDEN_ALLOW_PASSWORD=1
    fi

    if ((SSH_HARDEN_ALLOW_PASSWORD)); then
      SSH_HARDEN_USER_PASSWORD=$(netinstall::gen_password)
      log::add_secret "$SSH_HARDEN_USER_PASSWORD"
    fi
  fi

  # 3. porta SSH
  if flag::has tweak-ssh-change-port; then
    SSH_HARDEN_CHANGE_PORT=$(flag::get tweak-ssh-change-port 1)
  elif ((has_tty)) && ((!quick)); then
    tui::select "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'porta')" \
      'Alterar a porta SSH padrão?')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_CHANGE_PORT=1
  else
    SSH_HARDEN_CHANGE_PORT=1
  fi

  if ((SSH_HARDEN_CHANGE_PORT)); then
    SSH_HARDEN_PORT=$(flag::get tweak-ssh-port 21122)
    if ((has_tty)) && ((!quick)) && ! flag::has tweak-ssh-port; then
      tui::input 'porta SSH' 21122 \
        "$(tui::with_desc "$(tui::breadcrumb netinstall issabel5 'SSH' 'porta' 'número')" \
          'Porta que o sshd vai escutar depois do reboot.')" \
        || exit "$PVX_EXIT_ABORTED"
      SSH_HARDEN_PORT=$TUI_INPUT
    fi
    if [[ ! $SSH_HARDEN_PORT =~ ^[0-9]+$ ]] || ((SSH_HARDEN_PORT < 1 || SSH_HARDEN_PORT > 65535)); then
      log::error 'netinstall issabel5: --tweak-ssh-port inválido (precisa ser 1-65535): %s' "$SSH_HARDEN_PORT"
      exit "$PVX_EXIT_USAGE"
    fi
  fi
}

# netinstall::ssh_hardening_apply <lock_root> <root_pw> <create_user> <username> <pubkey>
# <allow_pw> <user_pw> <change_port> <port> [sshd_config] — só escreve/valida; NUNCA reinicia
# o sshd (ativa no reboot final do netinstall::_issabel5_finish).
netinstall::ssh_hardening_apply() {
  local lock_root=$1 root_pw=$2 create_user=$3 username=$4 pubkey=$5
  local allow_pw=$6 user_pw=$7 change_port=$8 port=$9
  local sshd_config=${10:-/etc/ssh/sshd_config}

  ((lock_root || create_user || change_port)) || return 0

  [[ -f $sshd_config ]] && srun -- cp --preserve "$sshd_config" "$sshd_config.bak.$(date +%F_%H%M%S)"

  if ((lock_root)); then
    log::info 'netinstall issabel5: ssh-hardening — bloqueando login SSH do root...'
    printf '%s:%s' root "$root_pw" | run -- chpasswd
    netinstall::sshd_config_upsert "$sshd_config" PermitRootLogin no
  fi

  if ((create_user)); then
    log::info 'netinstall issabel5: ssh-hardening — criando usuário dedicado %s...' "$username"
    id "$username" &>/dev/null || run -- useradd -m -s /bin/bash "$username"
    run -- usermod -aG wheel "$username"
    local home_dir ssh_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    ssh_dir="$home_dir/.ssh"
    run -- mkdir -p "$ssh_dir"
    run -- chmod 700 "$ssh_dir"
    run -- bash -c 'grep -qxF "$1" "$2" 2>/dev/null || printf "%s\n" "$1" >>"$2"' \
      -- "$pubkey" "$ssh_dir/authorized_keys"
    run -- chmod 600 "$ssh_dir/authorized_keys"
    run -- chown -R "$username:$username" "$ssh_dir"
    ((allow_pw)) && printf '%s:%s' "$username" "$user_pw" | run -- chpasswd
  fi

  if ((change_port)); then
    log::info 'netinstall issabel5: ssh-hardening — trocando a porta SSH para %s...' "$port"
    netinstall::sshd_config_upsert "$sshd_config" Port "$port"
  fi

  if ! run -- sshd -t -f "$sshd_config"; then
    log::error 'netinstall issabel5: ssh-hardening — sshd_config inválido, restaurando backup (mudanças de SSH NÃO aplicadas)'
    local backup
    backup=$(ls -t "$sshd_config".bak.* 2>/dev/null | head -n1)
    [[ -n $backup ]] && run -- cp --preserve "$backup" "$sshd_config"
  fi
}

# netinstall::render_astver_placeholder <arquivo> <astver> — os arquivos de pacote do legado
# têm literalmente "asterisk$ASTVER" (texto, não variável expandida — agora que a lista é um
# arquivo de dados puro). Substitui e imprime a lista pronta pro stdout.
netinstall::render_astver_placeholder() {
  local file=$1 astver=$2
  [[ -r $file ]] || return 0
  sed "s/\$ASTVER/$astver/g" "$file"
}
