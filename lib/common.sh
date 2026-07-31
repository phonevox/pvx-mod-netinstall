#!/usr/bin/env bash
# modules/netinstall/lib/common.sh — hardening e utilidades compartilhadas entre issabel4.sh e
# issabel5.sh. Exclusivo deste módulo: não é lib compartilhada do pvx-core (ver
# docs/module-authoring.md §3) — só usa o que já vem via `pvx::require` (color/log/os/exec/tui/net).

NETINSTALL_MIRROR_PROBE_URL=${NETINSTALL_MIRROR_PROBE_URL:-http://mirror.issabel.org}
NETINSTALL_FORCE=${NETINSTALL_FORCE:-0}
NETINSTALL_NO_TMUX=${NETINSTALL_NO_TMUX:-0}

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
  curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null "$NETINSTALL_MIRROR_PROBE_URL" 2>/dev/null || probe_rc=$?
  if ((probe_rc != 0)); then
    # dnf/yum vão bater nesse mesmo mirror via http:// mais adiante (ver config/repos*/*.repo) —
    # se a checagem falha aqui, a instalação de pacotes de verdade ia falhar do mesmo jeito lá
    # na frente, só que 15-20 minutos depois. Traduz o rc do curl pra apontar a causa provável
    # em vez de um "confira a rede" genérico — achado numa VPS onde ping/ICMP funcionava mas a
    # porta 80 estava bloqueada (curl rc=28, timeout de conexão).
    local motivo='motivo desconhecido'
    case $probe_rc in
      6) motivo='DNS não resolveu o host' ;;
      7) motivo='conexão recusada — nada escutando ou bloqueado antes de chegar no host' ;;
      28) motivo='timeout de conexão — porta provavelmente bloqueada por firewall (ping/ICMP pode funcionar mesmo assim, é outra porta)' ;;
      22 | 35 | 60) motivo='servidor respondeu, mas com erro HTTP/TLS' ;;
    esac
    log::error 'netinstall: não foi possível alcançar %s (curl rc=%d: %s)' \
      "$NETINSTALL_MIRROR_PROBE_URL" "$probe_rc" "$motivo"
    exit "$PVX_EXIT_UNAVAILABLE"
  fi

  exec::require_cmd rpm curl tmux || exit "$PVX_EXIT_UNAVAILABLE"
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

# netinstall::install_packages <rótulo> <pacote...> — substitui o yum_gauge/loop manual do
# legado: deixa o próprio dnf/yum mostrar progresso real de uma vez só, em vez de recalcular
# uma barra sintética pacote a pacote. Chamador é quem lê o arquivo de lista (mapfile) e faz a
# substituição de placeholder (ver netinstall::render_astver_placeholder) antes de chamar isto.
netinstall::install_packages() {
  local label=$1
  shift
  local -a pkgs=("$@")
  ((${#pkgs[@]} == 0)) && return 0
  log::info 'netinstall: instalando %s (%d pacotes)...' "$label" "${#pkgs[@]}"
  os::pkg_install "${pkgs[@]}"
}

# netinstall::flags_shared — flags comuns a `issabel4`/`issabel5`. Cada produto ainda declara
# a própria `--astver` (enum diferente por versão suportada) depois de chamar isto.
# --sql-password/--web-password via flag::add_secret já resolvem sozinhas, nesta ordem: flag
# explícita -> --*-file -> variável de ambiente -> prompt mascarado se houver TTY -> fallback
# (ver flag::_resolve_secret) — não precisa de lógica de wizard própria pra senha.
netinstall::flags_shared() {
  flag::add lang --default pt_BR --help 'idioma do sistema/Issabel'
  flag::add timezone --default 'America/Sao_Paulo' --help 'timezone do sistema e do PHP'
  flag::add addpkgs --repeat --help 'pacote adicional a instalar (pode repetir a flag)'
  flag::add upfront --type bool \
    --help 'pergunta tudo antes (flags e/ou wizard) e roda sem mais interação'
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
