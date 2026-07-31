#!/usr/bin/env bash
# modules/netinstall/lib/issabel4.sh — port de learning-materials/issabel-netinstall/
# (install.sh/settings.sh/utility.sh). Esse legado já era orientado a flags (sem `dialog`);
# aqui ele ganha os mesmos hardenings de issabel5.sh (preflight, tmux, senha aleatória,
# confirmação antes do reboot) e o parsing declarativo de lib/flags.sh em vez de um `case`
# manual. As 9 customizações Phonevox de px-customizations.sh (tema, avaliação/Voxura,
# firewall próprio, backup engine custom, siptracer, zoxide, fix de monitoramento/
# dialpatterns) não estão portadas — a flag existe e recusa com aviso claro em vez de
# fingir que fez algo.

NETINSTALL4_STUB_FLAGS='tema avaliacao firewall custom-backup-engine siptracer zoxide fix-monitoring-class fix-dialpatterns'

netinstall::_issabel4_addpkgs_help() {
  cat <<'EOF'
chaves válidas pra --addpkgs (issabel4): licensed, community-blocklist, wanpipe, callcenter
EOF
}

netinstall::_issabel4_resolve_addpkgs() {
  local key
  for key in "$@"; do
    case $key in
      licensed)
        printf '%s\n' issabel-license webconsole issabel-wizard issabel-packet_capture \
          issabel-upnpc issabel-two_factor_auth issabel-theme_designer issabel-network-agent
        ;;
      community-blocklist) printf '%s\n' issabel-packetbl ;;
      wanpipe) printf '%s\n' wanpipe-utils wanpipe ;;
      callcenter) printf '%s\n' issabel-callcenter ;;
      *)
        log::error 'netinstall issabel4: chave de --addpkgs desconhecida: %s' "$key"
        netinstall::_issabel4_addpkgs_help >&2
        exit "$PVX_EXIT_USAGE"
        ;;
    esac
  done
}

netinstall::run_issabel4() {
  netinstall::ensure_tmux issabel4 "$@"

  flag::reset
  flag::set_usage 'pvx netinstall issabel4' 'Instala o Issabel 4 do zero (CentOS/RHEL-like)'
  flag::add_standard
  netinstall::flags_shared
  flag::add astver --type enum --enum '11|13|16' --default 16 --help 'versão do Asterisk a instalar'
  flag::add addpkgs --repeat --help "$(netinstall::_issabel4_addpkgs_help)"
  local stub
  for stub in $NETINSTALL4_STUB_FLAGS; do
    flag::add "$stub" --type bool --help 'customização Phonevox — ainda não portada pro pvx'
  done
  flag::parse "$@" || return $?

  # shellcheck disable=SC2034 # lida por netinstall::preflight em lib/common.sh
  NETINSTALL_FORCE=${PVX_FLAG_VALUE[force]:-0}
  local has_tty=0
  [[ -t 0 && -t 1 ]] && has_tty=1

  netinstall::preflight issabel4
  netinstall::_issabel4_warn_stub_flags

  local astver=''
  local -a addpkgs_keys=()
  astver=$(flag::get astver '')
  if [[ -z $astver ]]; then
    if (( has_tty )); then
      tui::select "$(tui::breadcrumb netinstall issabel4)" 'Asterisk 11' 'Asterisk 13' 'Asterisk 16' ||
        exit "$PVX_EXIT_ABORTED"
      astver=${TUI_CHOICE##* }
    else
      log::error 'netinstall issabel4: --astver é obrigatório sem terminal interativo'
      exit "$PVX_EXIT_USAGE"
    fi
  fi

  if flag::has addpkgs; then
    IFS=$'\x1f' read -r -a addpkgs_keys <<<"${PVX_FLAG_MULTI[addpkgs]:-${PVX_FLAG_VALUE[addpkgs]}}"
  elif (( has_tty )); then
    tui::checklist "$(tui::breadcrumb netinstall issabel4)" \
      'licensed              módulos licenciados da Rede Issabel (issabel.guru)' \
      'community-blocklist   Community Realtime Block List' \
      'wanpipe               drivers Sangoma Wanpipe' \
      'callcenter            módulo Callcenter (recomendado só pra Asterisk 11)'
    local item
    for item in ${TUI_RESULT[@]+"${TUI_RESULT[@]}"}; do
      addpkgs_keys+=("${item%% *}")
    done
  fi

  local -a addpkgs=()
  if ((${#addpkgs_keys[@]})); then
    mapfile -t addpkgs < <(netinstall::_issabel4_resolve_addpkgs "${addpkgs_keys[@]}")
  fi

  # Resolve (e SÓ resolve — não aplica ainda) as senhas AQUI, junto de astver/addpkgs, antes da
  # confirmação destrutiva — mesmo achado do issabel5.sh (ver comentário lá): perguntar a senha
  # só no fim, depois de repos+pacotes+post_install+timezone, quebra o contrato de "pergunta
  # tudo que falta ANTES de começar" do README. Passa os valores já resolvidos adiante; QUEM
  # aplica a senha continua sendo _set_passwords, na mesma ordem de sempre.
  local sql_pw web_pw
  sql_pw=$(netinstall::resolve_secret_or_ask sql-password 'Defina a senha do MySQL')
  web_pw=$(netinstall::resolve_secret_or_ask web-password 'Defina a senha da interface Web')
  log::add_secret "$sql_pw"
  log::add_secret "$web_pw"

  log::info 'netinstall issabel4: Asterisk %s, pacotes extras: %s' "$astver" "${addpkgs_keys[*]:-nenhum}"

  if ! netinstall::confirm_destructive 'Prosseguir com a instalação do Issabel 4?'; then
    log::error 'netinstall issabel4: cancelado (sem confirmação)'
    exit "$PVX_EXIT_ABORTED"
  fi

  netinstall::_issabel4_prepare_system
  netinstall::_issabel4_add_repos
  netinstall::_issabel4_install_packages "$astver" "${addpkgs[@]}"
  netinstall::_issabel4_post_install
  netinstall::_issabel4_set_timezone
  netinstall::_issabel4_set_passwords "$sql_pw" "$web_pw"
  netinstall::_issabel4_finish
}

netinstall::_issabel4_warn_stub_flags() {
  local stub
  for stub in $NETINSTALL4_STUB_FLAGS; do
    # `if`, não `(( cond )) && cmd`: sob set -e, um `((cond))` falso solto (não protegido por
    # if/while/||) já retorna rc=1 e derruba o processo inteiro pela trap de ERR — mesma classe
    # de bug documentada em docs/interactive-menu-spec.md pro menu interativo.
    if (( ${PVX_FLAG_VALUE[$stub]:-0} )); then
      log::warn 'netinstall issabel4: --%s ainda não portado nesta versão do módulo — ignorado' "$stub"
    fi
  done
}

netinstall::_issabel4_prepare_system() {
  log::info 'netinstall issabel4: preparando o sistema (SELinux, grupo/usuário asterisk)...'
  local selinux_state
  selinux_state=$(os::selinux_state)
  log::debug 'netinstall issabel4: selinux_state=%s' "$selinux_state"
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
}

netinstall::_issabel4_add_repos() {
  log::info 'netinstall issabel4: adicionando repositórios do Issabel 4...'
  local repo_dir="$PVX_MODULE_DIR/config/repos4"
  if [[ -d $repo_dir ]]; then
    local f
    for f in "$repo_dir"/*.repo; do
      [[ -e $f ]] || continue
      srun -- install -m 0644 "$f" "/etc/yum.repos.d/${f##*/}"
    done
  fi
}

netinstall::_issabel4_install_packages() {
  local astver=$1
  shift
  local -a extra=("$@")
  local -a base issabel
  mapfile -t base <"$PVX_MODULE_DIR/lib/packages/issabel4-base.txt"
  mapfile -t issabel < <(netinstall::render_astver_placeholder "$PVX_MODULE_DIR/lib/packages/issabel4-issabel.txt" "$astver")
  srun -- dnf clean all
  netinstall::install_packages 'pacotes base' "${base[@]}"
  netinstall::install_packages 'pacotes Issabel + Asterisk + extras' "${issabel[@]}" ${extra[@]+"${extra[@]}"}
}

netinstall::_issabel4_post_install() {
  log::info 'netinstall issabel4: pós-instalação (mariadb, selinux, firewalld, asterisk)...'
  srun -- systemctl enable mariadb.service
  srun -- systemctl start mariadb

  local defaults_file
  defaults_file=$(exec::mysql_defaults_file root iSsAbEl.2o17)
  run -- mysql --defaults-extra-file="$defaults_file" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('iSsAbEl.2o17')" 2>/dev/null ||
    run -- mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('iSsAbEl.2o17')"

  srun -- cp -a /etc/sysconfig/iptables "/etc/sysconfig/iptables.org-issabel-$(date +%Y-%m-%d-%H-%M-%S)"
  srun -- systemctl enable httpd
  srun -- systemctl disable firewalld
  srun -- systemctl stop firewalld
  run -- firewall-cmd --zone=public --add-port=443/tcp --permanent
  run -- firewall-cmd --reload
  run -- rm -f /etc/issabel.conf

  run -- mysql --defaults-extra-file="$defaults_file" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('')"

  run -- bash -c "echo 'noload => cdr_mysql.so' >> /etc/asterisk/modules_additional.conf"
  srun -- mkdir --parents /var/log/asterisk/cdr-csv
  run -- mv -f /etc/asterisk/extensions_custom.conf.sample /etc/asterisk/extensions_custom.conf
  srun -- /usr/sbin/amportal chown

  local files_dir="$PVX_MODULE_DIR/config/files4"
  if [[ -f $files_dir/manager.conf.sample ]]; then
    run -- mv -f "$files_dir/manager.conf.sample" /etc/asterisk/manager.conf
  fi
  if [[ -f $files_dir/queues.conf.sample ]]; then
    run -- mv -f "$files_dir/queues.conf.sample" /etc/asterisk/queues.conf
  fi
}

netinstall::_issabel4_set_timezone() {
  local tz
  tz=$(flag::get timezone 'America/Sao_Paulo')
  log::info 'netinstall issabel4: ajustando timezone (%s)...' "$tz"
  if ! run -- timedatectl set-timezone "$tz"; then
    srun -- ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  fi
  run -- hwclock --hctosys

  local php_ini=/etc/php.ini
  if [[ -f $php_ini ]]; then
    srun -- cp --preserve "$php_ini" "$php_ini.bak.$(date +%F_%H%M)"
    srun -- sed -i "s#^;date\\.timezone\\s*=.*#date.timezone = ${tz//\//\\/}#" "$php_ini"
    if ! grep -q "date.timezone = ${tz}" "$php_ini" 2>/dev/null; then
      log::warn 'netinstall issabel4: não encontrei o placeholder de date.timezone em %s — confira manualmente' "$php_ini"
    fi
  fi
}

netinstall::_issabel4_set_passwords() {
  local sql_pw=$1 web_pw=$2
  log::info 'netinstall issabel4: definindo senhas de acesso (MySQL root / admin Web)...'

  if run --mask 3,4 -- /usr/bin/issabel-admin-passwords --cli init "$sql_pw" "$web_pw"; then
    :
  else
    log::warn 'netinstall issabel4: issabel-admin-passwords falhou/indisponível — rode manualmente depois'
  fi

  local cred_file
  cred_file=$(netinstall::save_credentials issabel4 "$sql_pw" "$web_pw")
  log::info 'netinstall issabel4: credenciais salvas em %s (0600) — só existem aí e nesta tela' "$cred_file"
}

netinstall::_issabel4_finish() {
  run -- bash -c "rm -f /tmp/inst1.txt /tmp/inst2.txt"
  srun -- /usr/sbin/amportal chown
  log::info 'netinstall issabel4: instalação concluída.'
  if (( ! ${PVX_FLAG_VALUE[reboot]:-1} )); then
    log::warn 'netinstall issabel4: --no-reboot passado — o servidor NÃO será reiniciado (faça isso manualmente)'
    return 0
  fi
  log::info 'netinstall issabel4: reiniciando o servidor...'
  run -- reboot
}
