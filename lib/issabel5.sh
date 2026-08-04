#!/usr/bin/env bash
# modules/netinstall/lib/issabel5.sh — port de learning-materials/pissabel5/issabel5-netinstall.sh.
# Usa lib/tui.sh em vez de `dialog`, e run/srun/os::pkg_install/exec::mysql_defaults_file em vez
# de yum/sed/mysql crus. Não inclui a camada de customizações Phonevox do issabel4 (tema,
# avaliação, firewall etc.) — o issabel5 legado nunca teve essas, só control_panel + timezone.
#
# `pvx netinstall issabel5` roda o fluxo próprio do pvx (tudo abaixo, ver
# netinstall::_issabel5_custom) por padrão — o instalador RAW legado (github.com/phonevox/
# pissabel5) fica disponível via --legacy. Ver netinstall::_issabel5_raw pro dispatch.
#
# O fluxo próprio cobre o mesmo problema de resolução de pacote que o raw sempre tratou via
# centos8_tweaks (repo Remi + módulo php:remi-7.4 + powertools/devel) — ver
# netinstall::_issabel5_enable_php_remi. Sem isso, php-imap/php-mcrypt/php-tidy (e qualquer
# outro pacote php-* que dependa deles, ex: php-PHPMailer/php-tcpdf) não existem no módulo php
# padrão do AppStream, e o dnf install de "pacotes base + Asterisk" falhava com "No match for
# argument" pra cada um — motivo pelo qual o fluxo próprio virou o padrão (era opt-in via
# --custom antes disso ser corrigido e validado numa VPS real de ponta a ponta).

netinstall::_issabel5_addpkgs_help() {
  cat <<'EOF'
chaves válidas pra --addpkgs (issabel5): licensed, community-blocklist, wanpipe
EOF
}

# netinstall::_issabel5_resolve_addpkgs <chave...> — imprime os nomes de pacote reais, um por
# linha. Chave desconhecida é erro alto (nunca instala "o que der" silenciosamente).
netinstall::_issabel5_resolve_addpkgs() {
  local key
  for key in "$@"; do
    case $key in
      licensed)
        printf '%s\n' issabel-license webconsole issabel-wizard issabel-packet_capture \
          issabel-upnpc issabel-two_factor_auth issabel-theme_designer issabel-network-agent
        ;;
      community-blocklist) printf '%s\n' issabel-packetbl ;;
      wanpipe) printf '%s\n' wanpipe-utils wanpipe ;;
      *)
        log::error 'netinstall issabel5: chave de --addpkgs desconhecida: %s' "$key"
        netinstall::_issabel5_addpkgs_help >&2
        exit "$PVX_EXIT_USAGE"
        ;;
    esac
  done
}

# netinstall::run_issabel5 "$@" — despacha ANTES de qualquer flag::parse "de verdade" entre os
# dois fluxos possíveis (mesmo padrão de netinstall::ensure_tmux, que já varre argv cru pelo
# mesmo motivo): por padrão, roda o fluxo próprio do pvx (flags, tui, resumo, etc.); com
# `--legacy`, roda o instalador RAW do issabel5 (issabel5-netinstall.sh do github.com/phonevox/
# pissabel5, sem modificação nenhuma — literalmente baixa e executa).
#
# `--custom` continua aceito (bool, sem efeito) só por compatibilidade com quem já tinha esse
# hábito de digitar — o fluxo próprio é o padrão agora, não precisa mais ser pedido.
netinstall::run_issabel5() {
  local a legacy=0 help=0
  for a in "$@"; do
    case $a in
      --legacy) legacy=1 ;;
      -h | --help) help=1 ;;
    esac
  done

  if (( help && legacy )); then
    # --legacy junto com --help: mostra só o uso mínimo do modo raw (ele não aceita flag
    # nenhuma, é literalmente o script legado); sem --legacy, deixa cair pro flag::parse
    # abaixo, que já imprime o --help completo do fluxo pvx (agora o padrão).
    cat <<'EOF'
uso: pvx netinstall issabel5 --legacy

--legacy: baixa e executa o instalador raw do Issabel 5 (github.com/phonevox/pissabel5), sem
nenhuma modificação — o mesmo wizard interativo (dialog) de sempre, sem flags/upfront do pvx.

Sem --legacy (padrão): usa o fluxo próprio do pvx (flags, prompts, resumo antes de confirmar,
etc.) — ver --help (sem --legacy) pra lista completa de flags.
EOF
    return 0
  fi

  if (( legacy )); then
    netinstall::_issabel5_raw "$@"
    return $?
  fi

  netinstall::_issabel5_custom "$@"
}

# netinstall::_issabel5_raw "$@" — baixa (git clone/pull, raso) o instalador legado do
# github.com/phonevox/pissabel5 pro state dir do módulo e o EXECUTA sem nenhuma modificação —
# nenhuma flag do pvx é repassada pra ele (o script não entende nenhuma, é 100% dialog
# interativo). Reusa preflight/ensure_tmux (as mesmas checagens de root/rede/tmux de sempre)
# antes de entregar o controle: falhar rápido aqui é melhor que deixar o script legado
# descobrir sozinho, 20 minutos depois, que não tinha rede.
netinstall::_issabel5_raw() {
  netinstall::ensure_tmux issabel5 "$@"
  netinstall::preflight issabel5 8

  exec::require_cmd git || exit "$PVX_EXIT_UNAVAILABLE"

  local repo_dir="${PVX_MODULE_STATE_DIR:?PVX_MODULE_STATE_DIR não definido}/pissabel5-raw"
  if [[ -d "$repo_dir/.git" ]]; then
    log::info 'netinstall issabel5: atualizando o instalador raw (%s)...' "$repo_dir"
    srun --cwd "$repo_dir" -- git pull --ff-only
  else
    rm -rf "$repo_dir"
    log::info 'netinstall issabel5: baixando o instalador raw (github.com/phonevox/pissabel5)...'
    srun -- git clone --depth 1 https://github.com/phonevox/pissabel5.git "$repo_dir"
  fi

  if [[ ! -r "$repo_dir/issabel5-netinstall.sh" ]]; then
    log::error 'netinstall issabel5: issabel5-netinstall.sh não encontrado em %s — clone/pull falhou?' "$repo_dir"
    exit "$PVX_EXIT_UNAVAILABLE"
  fi
  srun -- chmod +x "$repo_dir/issabel5-netinstall.sh"

  log::info 'netinstall issabel5: entregando o controle pro instalador raw (sem flags do pvx — tire --legacy pro fluxo próprio, que é o padrão)...'
  exec bash -c 'cd "$1" && exec ./issabel5-netinstall.sh' -- "$repo_dir"
}

netinstall::_issabel5_custom() {
  netinstall::ensure_tmux issabel5 "$@"

  flag::reset
  flag::set_usage 'pvx netinstall issabel5' 'Instala o Issabel 5 do zero (Rocky/CentOS/RHEL 8) via o fluxo próprio do pvx'
  flag::add_standard
  netinstall::flags_shared
  # aceita e ignora — este é o fluxo padrão agora; --custom só existe pra não quebrar quem já
  # tinha o hábito de digitar. Ver netinstall::run_issabel5 pro dispatch de verdade (--legacy).
  flag::add custom --type bool --help 'sem efeito — este já é o fluxo padrão (aceito só por compatibilidade)'
  # SEM --default de propósito: um --default preenche flag::get antes do `[[ -z $astver ]]`
  # embaixo sequer rodar, matando pra sempre o caminho interativo (achado de verdade: o
  # seletor de Asterisk 16/18 nunca aparecia, a instalação sempre seguia direto pro Asterisk
  # 18 em silêncio, mesmo sem --astver — o "default" da flag já resolvia tudo antes de chegar
  # no `if [[ -z $astver ]]`). Sem terminal E sem --astver, cai no erro claro logo abaixo, que
  # é o comportamento documentado no README (não um valor mudo escolhido por baixo dos panos).
  flag::add astver --type enum --enum '16|18' --short a --help 'versão do Asterisk a instalar (pergunta interativamente se omitida com terminal)'
  flag::add addpkgs --repeat --help "$(netinstall::_issabel5_addpkgs_help)"
  flag::parse "$@" || return $?

  # shellcheck disable=SC2034 # lida por netinstall::preflight em lib/common.sh
  NETINSTALL_FORCE=${PVX_FLAG_VALUE[force]:-0}
  local has_tty=0
  [[ -t 0 && -t 1 ]] && has_tty=1

  netinstall::preflight issabel5 8

  local astver=''
  local -a addpkgs_keys=()
  astver=$(flag::get astver '')
  if [[ -z $astver ]]; then
    if (( has_tty )); then
      tui::select "$(tui::breadcrumb netinstall issabel5 'Asterisk')" 'Asterisk 16' 'Asterisk 18' || exit "$PVX_EXIT_ABORTED"
      [[ $TUI_CHOICE == 'Asterisk 16' ]] && astver=16 || astver=18
    else
      log::error 'netinstall issabel5: --astver é obrigatório sem terminal interativo'
      exit "$PVX_EXIT_USAGE"
    fi
  fi

  if flag::has addpkgs; then
    IFS=$'\x1f' read -r -a addpkgs_keys <<<"${PVX_FLAG_MULTI[addpkgs]:-${PVX_FLAG_VALUE[addpkgs]}}"
  elif (( has_tty )); then
    # licensed e community-blocklist já vêm marcados (mesmo default do dialog legado); wanpipe
    # fica desmarcado (drivers de hardware específico, não algo pra ligar sem saber que precisa).
    TUI_CHECKLIST_DEFAULT=(1 1 0)
    tui::checklist "$(tui::breadcrumb netinstall issabel5 'Pacotes adicionais')" \
      'licensed              módulos licenciados da Rede Issabel (issabel.guru)' \
      'community-blocklist   Community Realtime Block List (bloqueia IPs SIP ofensores conhecidos)' \
      'wanpipe               drivers Sangoma Wanpipe'
    local item
    for item in ${TUI_RESULT[@]+"${TUI_RESULT[@]}"}; do
      addpkgs_keys+=("${item%% *}")
    done
  fi

  local -a addpkgs=()
  if ((${#addpkgs_keys[@]})); then
    mapfile -t addpkgs < <(netinstall::_issabel5_resolve_addpkgs "${addpkgs_keys[@]}")
  fi

  # Resolve (e SÓ resolve — não aplica ainda) as senhas AQUI, junto de astver/addpkgs, antes da
  # confirmação destrutiva. Achado de verdade: perguntar a senha só no fim (como era antes,
  # dentro de _issabel5_set_passwords, chamada depois de repos+pacotes+post_install+painel+
  # timezone) quebra o contrato de "pergunta tudo que falta ANTES de começar" do README — o
  # operador confirma a instalação achando que já respondeu tudo, sai da tela por 15-20min de
  # dnf, e ou volta pra achar o processo parado esperando teclado numa etapa tardia, ou (pior)
  # a instalação cai no meio (rede, OOM, etc.) e a pergunta nunca chega a aparecer. Passa os
  # valores já resolvidos adiante; QUEM aplica a senha continua sendo _set_passwords, na mesma
  # ordem de sempre (só dá pra rodar issabel-admin-passwords depois do Issabel instalado).
  local sql_pw web_pw
  sql_pw=$(netinstall::resolve_secret_or_ask sql-password "$(tui::breadcrumb netinstall issabel5 'MySQL')" 'Defina a senha do MySQL')
  web_pw=$(netinstall::resolve_secret_or_ask web-password "$(tui::breadcrumb netinstall issabel5 'Web Interface')" 'Defina a senha da interface Web')
  log::add_secret "$sql_pw"
  log::add_secret "$web_pw"

  local addpkgs_display='nenhum'
  if ((${#addpkgs_keys[@]})); then
    addpkgs_display=$(IFS=', '; printf '%s' "${addpkgs_keys[*]}")
  fi
  netinstall::print_summary issabel5 "$astver" "$addpkgs_display"

  if ! netinstall::confirm_destructive 'Prosseguir com a instalação do Issabel 5?'; then
    log::error 'netinstall issabel5: cancelado (sem confirmação)'
    exit "$PVX_EXIT_ABORTED"
  fi

  # add_repos ANTES de prepare_system, não depois: prepare_system instala
  # issabel-config_helpers, um pacote que só existe no repo do Issabel — instalar antes do
  # repo existir faz o dnf procurar em repositórios que nunca vão ter esse pacote (parece
  # travado: nenhuma saída aparece até o dnf desistir, já que run/srun só mostram a saída
  # depois que o comando termina). Ordem trocada, igual o script legado sempre fez.
  netinstall::_issabel5_add_repos
  netinstall::_issabel5_prepare_system
  netinstall::_issabel5_enable_php_remi
  netinstall::_issabel5_install_packages "$astver" "${addpkgs[@]}"
  netinstall::_issabel5_post_install
  netinstall::_issabel5_control_panel
  netinstall::_issabel5_set_timezone
  netinstall::_issabel5_set_passwords "$sql_pw" "$web_pw"
  netinstall::_issabel5_finish
}

netinstall::_issabel5_prepare_system() {
  log::info 'netinstall issabel5: preparando o sistema (SELinux, grupo/usuário asterisk)...'
  local selinux_state
  selinux_state=$(os::selinux_state)
  log::debug 'netinstall issabel5: selinux_state=%s' "$selinux_state"
  if [[ $selinux_state != disabled ]]; then
    run --timeout 10 -- setenforce 0
  fi
  if [[ -f /etc/selinux/config ]]; then
    srun -- sed -i 's/\(^SELINUX=\).*/SELINUX=disabled/' /etc/selinux/config
  fi
  run -- /usr/sbin/groupadd -f -r asterisk
  if ! grep -q '^asterisk:' /etc/passwd 2>/dev/null; then
    srun -- /usr/sbin/useradd -r -g asterisk -c 'Asterisk PBX' -s /bin/bash -d /var/lib/asterisk asterisk
  fi
  # sem run/srun aqui de propósito: os::pkg_install já é run-aware por dentro (chama `run --
  # "$mgr" install -y ...`); envolver de novo só esconderia o dnf/yum real atrás de uma linha
  # de dry-run genérica ("$ os::pkg_install ...") em vez do comando de verdade.
  #
  # log::info ANTES de cada instalação individual, de propósito: run/srun só mostram a saída
  # do dnf DEPOIS que ele termina (não streaming em tempo real, ver comentário em
  # lib/exec.sh:exec::_run_impl) — sem um aviso prévio, um dnf lento (rede ruim, metadata
  # grande) fica minutos sem imprimir nada, parecendo travado. Achado de verdade numa VPS.
  log::info 'netinstall issabel5: instalando issabel-config_helpers...'
  os::pkg_install issabel-config_helpers
}

netinstall::_issabel5_add_repos() {
  log::info 'netinstall issabel5: adicionando repositórios (epel, tmux/htop, Issabel 5)...'
  log::info 'netinstall issabel5: instalando epel-release...'
  os::pkg_install epel-release
  log::info 'netinstall issabel5: atualizando metadata dos repositórios (dnf makecache)...'
  srun -- dnf makecache
  log::info 'netinstall issabel5: instalando htop e tmux...'
  os::pkg_install htop tmux
  run -- bash -c "grep -qxF 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf; sysctl -p"

  local repo_dir=$PVX_MODULE_DIR/config/repos
  if [[ -d $repo_dir ]]; then
    local f
    for f in "$repo_dir"/*.repo; do
      [[ -e $f ]] || continue
      srun -- install -m 0644 "$f" "/etc/yum.repos.d/${f##*/}"
    done
  fi
}

# netinstall::_issabel5_enable_php_remi — port do passo centos8_tweaks do script legado
# (github.com/phonevox/pissabel5): sem o repo Remi + módulo php:remi-7.4, o módulo php padrão
# do AppStream (RHEL/Rocky 8) não tem php-imap/php-mcrypt/php-tidy (removidos do PHP core desde
# o 7.x) — nem os pacotes que dependem deles (ex: php-PHPMailer, php-tcpdf). O raw sempre
# rodou isto antes da lista de pacotes; o --custom nunca rodou, e por isso falhava com "No
# match for argument" onde o raw funcionava. powertools/devel entram pelo mesmo motivo do
# legado: dependências de build/dev de alguns pacotes Issabel/PHP vêm de lá, não do AppStream
# base.
#
# `dnf module reset php -y` ANTES do enable, de propósito: se o stream padrão do módulo php
# (7.2, AppStream) já foi tocado antes (ex: uma tentativa anterior desta instalação que morreu
# no meio, ou qualquer dnf install php prévio), o dnf recusa a troca direta de stream com "It is
# not possible to switch enabled streams of a module" — reset é sempre seguro mesmo quando o
# módulo nunca foi habilitado (não-op nesse caso), e sem ele um retry nesta mesma máquina
# quebraria de novo, agora num ponto diferente. Achado de verdade rodando isto de propósito numa
# VPS que já tinha uma tentativa anterior (sem este fix) parcialmente instalada.
netinstall::_issabel5_enable_php_remi() {
  local major
  major=$(os::version_major)
  log::info 'netinstall issabel5: habilitando repo Remi + módulo php:remi-7.4 (RHEL/Rocky %s)...' "$major"
  os::pkg_install "https://rpms.remirepo.net/enterprise/remi-release-${major}.rpm"
  srun -- dnf module reset php -y
  srun -- dnf module enable php:remi-7.4 -y
  srun -- dnf config-manager --set-enabled remi
  srun -- dnf config-manager --set-enabled powertools
  srun -- dnf config-manager --set-enabled devel
}

netinstall::_issabel5_install_packages() {
  local astver=$1
  shift
  local -a extra=("$@")
  local -a base issabel
  mapfile -t base < <(netinstall::render_astver_placeholder "$PVX_MODULE_DIR/lib/packages/issabel5-base.txt" "$astver")
  mapfile -t issabel <"$PVX_MODULE_DIR/lib/packages/issabel5-issabel.txt"
  srun -- dnf clean all
  netinstall::install_packages 'pacotes base + Asterisk' "${base[@]}"
  netinstall::install_packages 'pacotes Issabel + extras' "${issabel[@]}" ${extra[@]+"${extra[@]}"}
}

netinstall::_issabel5_post_install() {
  log::info 'netinstall issabel5: pós-instalação (mariadb, selinux, firewalld, asterisk)...'
  srun -- systemctl enable mariadb.service
  srun -- systemctl start mariadb

  local defaults_file
  defaults_file=$(exec::mysql_defaults_file root iSsAbEl.2o17)
  run -- mysql --defaults-extra-file="$defaults_file" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('iSsAbEl.2o17')" 2>/dev/null ||
    run -- mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('iSsAbEl.2o17')"

  srun -- systemctl enable httpd

  # firewalld é OPCIONAL aqui, não requisito: várias imagens de VPS/cloud pra Rocky Linux não
  # vêm com firewalld instalado (iptables cru, nftables direto, firewall só na borda, etc.).
  # Achado de verdade: `srun -- systemctl disable firewalld` (fatal) abortava a instalação
  # inteira no meio do pós-processamento só porque firewalld.service nem existia na máquina —
  # detecta a presença ANTES de mexer, em vez de tentar e só depois descobrir que não tinha
  # nada pra desativar. O backup do iptables (arquivo legado, só existe com iptables-services)
  # tem a mesma checagem, pelo mesmo motivo.
  if command -v firewall-cmd >/dev/null 2>&1; then
    if [[ -f /etc/sysconfig/iptables ]]; then
      run -- cp -a /etc/sysconfig/iptables "/etc/sysconfig/iptables.org-issabel-$(date +%Y-%m-%d-%H-%M-%S)"
    fi
    run -- systemctl disable firewalld
    run -- systemctl stop firewalld
    run -- firewall-cmd --zone=public --add-port=443/tcp --permanent
    run -- firewall-cmd --reload
  else
    log::debug 'netinstall issabel5: firewalld não está instalado — pulando (nada a desativar)'
  fi
  run -- rm -f /etc/issabel.conf

  run -- mysql --defaults-extra-file="$defaults_file" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('')"

  run -- bash -c "grep -qxF 'noload => cdr_mysql.so' /etc/asterisk/modules_additional.conf 2>/dev/null || echo 'noload => cdr_mysql.so' >> /etc/asterisk/modules_additional.conf"
  srun -- mkdir --parents /var/log/asterisk/cdr-csv
  if [[ -f /etc/asterisk/extensions_custom.conf.sample ]]; then
    run -- mv -f /etc/asterisk/extensions_custom.conf.sample /etc/asterisk/extensions_custom.conf
  fi
  # `if run ...; then :; else ...; fi`, não uma chamada solta — /usr/sbin/amportal só existe
  # depois do primeiro acesso ao wizard web do Issabel (que este netinstall não roda), então NÃO
  # existir aqui é esperado, não um erro real. O legado (issabel5-netinstall.sh) faz a mesma
  # chamada nos mesmos dois pontos e nunca notava a falha porque envolve tudo isto em
  # "(...) &> /dev/null". Aqui, sob `set -e`, uma chamada solta a `run` (mesmo sem `srun`) ainda
  # propaga o rc != 0 pro chamador e dispara o errexit — `run` só evita o `exit` interno de
  # exec::_run_impl, não blinda quem chamou (mesmo padrão já usado logo abaixo, em
  # _issabel5_set_passwords, pro issabel-admin-passwords). Achado de verdade: rodando --custom do
  # zero numa VPS limpa, a instalação completa (repos, ~60 pacotes, control_panel, timezone,
  # senhas) e só quebrava aqui, em algo que o próprio legado já tratava como best-effort.
  if run -- /usr/sbin/amportal chown; then
    :
  else
    log::debug 'netinstall issabel5: amportal chown falhou/indisponível (esperado sem o wizard web do Issabel) — ignorando'
  fi
}

netinstall::_issabel5_control_panel() {
  local src="$PVX_MODULE_DIR/config/control_panel"
  [[ -d $src ]] || return 0
  log::info 'netinstall issabel5: instalando módulo control_panel...'
  run -- rm -rf /var/www/html/modules/control_panel
  srun -- cp -r "$src" /var/www/html/modules/control_panel
  srun -- chown -R asterisk:asterisk /var/www/html/modules/control_panel
  srun -- chmod -R 755 /var/www/html/modules/control_panel
  run -- sqlite3 /var/www/db/acl.db \
    "INSERT INTO acl_resource (name, description) SELECT 'control_panel','Issabel Panel' WHERE NOT EXISTS (SELECT 1 FROM acl_resource WHERE name='control_panel');"
  run -- sqlite3 /var/www/db/menu.db \
    "INSERT INTO menu (id, IdParent, Link, Name, Type, order_no) SELECT 'control_panel','pbxconfig','','Issabel Panel','module',8 WHERE NOT EXISTS (SELECT 1 FROM menu WHERE id='control_panel');"
  run -- sqlite3 /var/www/db/acl.db \
    "INSERT INTO acl_group_permission (id_action, id_group, id_resource) SELECT 1,1,(SELECT id FROM acl_resource WHERE name='control_panel') WHERE NOT EXISTS (SELECT 1 FROM acl_group_permission WHERE id_group=1 AND id_resource=(SELECT id FROM acl_resource WHERE name='control_panel'));"
}

netinstall::_issabel5_set_timezone() {
  local tz
  tz=$(flag::get timezone 'America/Sao_Paulo')
  log::info 'netinstall issabel5: ajustando timezone (%s)...' "$tz"
  if ! run -- timedatectl set-timezone "$tz"; then
    srun -- ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  fi
  run -- hwclock --hctosys

  local php_ini=/etc/php.ini
  if [[ -f $php_ini ]]; then
    srun -- cp --preserve "$php_ini" "$php_ini.bak.$(date +%F_%H%M)"
    srun -- sed -i "s#^;date\\.timezone\\s*=.*#date.timezone = ${tz//\//\\/}#" "$php_ini"
    if ! grep -q "date.timezone = ${tz}" "$php_ini" 2>/dev/null; then
      log::warn 'netinstall issabel5: não encontrei o placeholder de date.timezone em %s — confira manualmente' "$php_ini"
    fi
  fi
}

netinstall::_issabel5_set_passwords() {
  local sql_pw=$1 web_pw=$2
  log::info 'netinstall issabel5: definindo senhas de acesso (MySQL root / admin Web)...'

  if run --mask 3,4 -- /usr/bin/issabel-admin-passwords --cli init "$sql_pw" "$web_pw"; then
    :
  else
    log::warn 'netinstall issabel5: issabel-admin-passwords falhou/indisponível — rode manualmente depois'
  fi

  local cred_file
  cred_file=$(netinstall::save_credentials issabel5 "$sql_pw" "$web_pw")
  log::info 'netinstall issabel5: credenciais salvas em %s (0600) — só existem aí e nesta tela' "$cred_file"
}

netinstall::_issabel5_finish() {
  run -- bash -c "rm -f /tmp/inst1.txt /tmp/inst2.txt"
  # `if run ...; then :; else ...; fi`, não uma chamada solta — /usr/sbin/amportal só existe
  # depois do primeiro acesso ao wizard web do Issabel (que este netinstall não roda), então NÃO
  # existir aqui é esperado, não um erro real. O legado (issabel5-netinstall.sh) faz a mesma
  # chamada nos mesmos dois pontos e nunca notava a falha porque envolve tudo isto em
  # "(...) &> /dev/null". Aqui, sob `set -e`, uma chamada solta a `run` (mesmo sem `srun`) ainda
  # propaga o rc != 0 pro chamador e dispara o errexit — `run` só evita o `exit` interno de
  # exec::_run_impl, não blinda quem chamou (mesmo padrão já usado logo abaixo, em
  # _issabel5_set_passwords, pro issabel-admin-passwords). Achado de verdade: rodando --custom do
  # zero numa VPS limpa, a instalação completa (repos, ~60 pacotes, control_panel, timezone,
  # senhas) e só quebrava aqui, em algo que o próprio legado já tratava como best-effort.
  if run -- /usr/sbin/amportal chown; then
    :
  else
    log::debug 'netinstall issabel5: amportal chown falhou/indisponível (esperado sem o wizard web do Issabel) — ignorando'
  fi
  log::info 'netinstall issabel5: instalação concluída.'
  if (( ! ${PVX_FLAG_VALUE[reboot]:-1} )); then
    log::warn 'netinstall issabel5: --no-reboot passado — o servidor NÃO será reiniciado (faça isso manualmente)'
    return 0
  fi
  log::info 'netinstall issabel5: reiniciando o servidor...'
  run -- reboot
}
