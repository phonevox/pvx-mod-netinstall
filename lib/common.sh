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

# netinstall::preflight <produto> — bloqueia cedo em vez de deixar o `dnf install` de ~600
# pacotes falhar 20 minutos depois. Cada checagem já loga o motivo específico antes de sair.
netinstall::preflight() {
  local produto=$1

  os::require_root "netinstall $produto"

  os::require_rhel_like "netinstall $produto" || exit "$PVX_EXIT_UNSUPPORTED"
  os::require_min_version 8 "netinstall $produto" || exit "$PVX_EXIT_UNSUPPORTED"

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
netinstall::ensure_tmux() {
  local produto=$1
  shift
  [[ -n ${TMUX:-} ]] && return 0
  local a
  for a in "$@"; do
    case $a in
      --no-tmux | -h | --help) return 0 ;;
    esac
  done
  if ! command -v tmux >/dev/null 2>&1; then
    log::warn 'netinstall: tmux não encontrado — continuando sem sessão persistente (instale tmux ou use --no-tmux pra silenciar este aviso)'
    return 0
  fi

  local session="pvx-netinstall-$produto"
  log::info 'netinstall: iniciando dentro de uma sessão tmux (%s); use --no-tmux pra desligar isso' \
    "$session"
  exec tmux new-session -s "$session" -- "$0" "$produto" "$@"
}

# netinstall::ask_password <rótulo> — prompt mascarado (sem eco, igual a um `sudo`); enter
# vazio (ou sem TTY nenhum) gera uma senha aleatória em vez de aceitar "" como senha de
# verdade — nunca trava esperando teclado fora de terminal interativo.
#
# Só checa "-t 0" (stdin), NUNCA "-t 1" (stdout): esta função é sempre chamada via
# `v=$(netinstall::ask_password ...)` pra capturar o valor — e a própria substituição de
# comando redireciona o stdout do que está dentro pra um pipe, o que faz "-t 1" dar falso
# SEMPRE, mesmo com terminal de verdade (achado rodando de verdade: a pergunta nunca
# disparava, sempre gerava senha aleatória mesmo digitando algo). stdin não é tocado pelo
# $(...), então "-t 0" continua refletindo o terminal real do processo inteiro.
#
# NUNCA `read -p ... 2>/dev/null` na mesma chamada — mesmo achado já documentado em
# exec::confirm (lib/exec.sh): o bash escreve o texto de `-p` em STDERR, e um `2>/dev/null`
# ali junto apaga o prompt inteiro, não só erros de verdade. Achado de novo rodando contra a
# VPS: a pergunta de senha nunca aparecia (parecia que só o "Prosseguir com a instalação?"
# pedia confirmação) e era preciso apertar enter APROVEITANDO ÀS CEGAS pra passar por cada
# prompt invisível (um pro sql-password, um pro web-password) antes da confirmação de verdade
# aparecer — exatamente o "precisa apertar enter 3x" relatado. Corrigido imprimindo o prompt
# separado (sempre em stderr, nunca stdout — senão contaminaria o valor capturado pelo `$(...)`
# do chamador) e só then lendo, sem prompt nenhum pendurado no `read` que tem o `2>/dev/null`.
netinstall::ask_password() {
  local label=$1 v=''
  if [[ -t 0 ]]; then
    printf '%s (enter pra gerar aleatória): ' "$label" >&2
    IFS= read -rs v </dev/tty 2>/dev/null || v=''
    printf '\n' >&2
  fi
  [[ -z $v ]] && v=$(netinstall::gen_password)
  printf '%s' "$v"
}

# netinstall::resolve_secret_or_ask <flag> <rótulo> — usa o valor já resolvido por
# --<flag>/--<flag>-file/variável de ambiente se qualquer um desses foi dado (mesma prioridade
# de flag::_resolve_secret); só cai em netinstall::ask_password se nenhum dos três veio —
# assim a pergunta usa nosso texto (com "gera aleatória" explícito) em vez do prompt genérico
# de lib/flags.sh, sem duplicar a lógica de resolução de --flag/--flag-file/env.
netinstall::resolve_secret_or_ask() {
  local long=$1 label=$2 env
  if flag::has "$long" || flag::has "$long-file"; then
    flag::get "$long"
    return 0
  fi
  env=${PVX_FLAG_ENV[$long]:-}
  if [[ -n $env && -n ${!env:-} ]]; then
    flag::get "$long"
    return 0
  fi
  netinstall::ask_password "$label"
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

# netinstall::save_credentials <produto> <sql_password> <web_password> — grava uma única vez
# em $PVX_MODULE_STATE_DIR (0600) e devolve o caminho — é a única cópia recuperável depois que
# a tela rolar.
netinstall::save_credentials() {
  local produto=$1 sql_pw=$2 web_pw=$3 dir file ts
  dir=${PVX_MODULE_STATE_DIR:?PVX_MODULE_STATE_DIR não definido}
  mkdir -p "$dir"
  printf -v ts '%(%Y%m%dT%H%M%S)T' -1
  file="$dir/credentials-$produto-$ts.txt"
  {
    printf 'produto=%s\n' "$produto"
    printf 'data=%s\n' "$ts"
    printf 'mysql_root_password=%s\n' "$sql_pw"
    printf 'web_admin_password=%s\n' "$web_pw"
  } >"$file"
  chmod 0600 "$file"
  printf '%s' "$file"
}

# netinstall::confirm_destructive <mensagem> — gate antes de SELinux/firewalld off + reboot
# final. Ao contrário do legado (nunca perguntava nada aqui), falha FECHADO sem TTY e sem
# --yes: nunca reinicia um servidor sozinho sem ninguém ter autorizado explicitamente.
netinstall::confirm_destructive() {
  local msg=$1
  exec::confirm "$msg (SELinux/firewalld serão desativados e o servidor será reiniciado) [s/N]" n
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

# netinstall::render_astver_placeholder <arquivo> <astver> — os arquivos de pacote do legado
# têm literalmente "asterisk$ASTVER" (texto, não variável expandida — agora que a lista é um
# arquivo de dados puro). Substitui e imprime a lista pronta pro stdout.
netinstall::render_astver_placeholder() {
  local file=$1 astver=$2
  [[ -r $file ]] || return 0
  sed "s/\$ASTVER/$astver/g" "$file"
}
