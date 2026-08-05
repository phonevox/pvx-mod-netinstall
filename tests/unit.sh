#!/usr/bin/env bash
# tests/unit.sh — regressão das funções puras do módulo (resolução de --addpkgs, substituição
# de $ASTVER nas listas de pacote, geração de senha). Sem rede, sem tocar no sistema — não
# testa instalação de verdade (isso é smoke manual dentro do testrocky, ver README.md).
#
# Mini-framework próprio de propósito: este repo não depende do tests/lib/assert.sh do pvxcli
# (repos separados, ver docs/module-authoring.md no pvxcli) — não vale a pena vendorizar o
# framework inteiro pra ~15 asserções.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODULE_DIR=$(cd -P "$_TEST_DIR/.." && pwd)

: "${PVX_ROOT:?defina PVX_ROOT apontando pro checkout do pvxcli antes de rodar isto}"
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR PVX_MODULE_DIR="$MODULE_DIR"

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os exec tui flags net
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init

# shellcheck source=/dev/null
source "$MODULE_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$MODULE_DIR/lib/issabel4.sh"
# shellcheck source=/dev/null
source "$MODULE_DIR/lib/issabel5.sh"

_PASS=0
_FAIL=0

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok - %s\n' "$desc"
    _PASS=$((_PASS + 1))
  else
    printf '  FALHOU - %s (esperado=[%s] obtido=[%s])\n' "$desc" "$expected" "$actual" >&2
    _FAIL=$((_FAIL + 1))
  fi
}

assert_rc() {
  local desc=$1 expected=$2
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$desc" "$expected" "$rc"
}

# --- resolução de --addpkgs (issabel5) ------------------------------------------------------
out=$(netinstall::_issabel5_resolve_addpkgs community-blocklist wanpipe)
assert_eq 'issabel5: community-blocklist resolve pro pacote real' \
  "$(printf 'issabel-packetbl\nwanpipe-utils\nwanpipe')" "$out"
assert_rc 'issabel5: chave desconhecida falha alto (não instala "o que der")' \
  "$PVX_EXIT_USAGE" bash -c '
    source "$PVX_LIB_DIR/bootstrap.sh"
    pvx::require color log os exec tui flags net
    color::init; log::init
    source "$PVX_MODULE_DIR/lib/common.sh"
    source "$PVX_MODULE_DIR/lib/issabel5.sh"
    netinstall::_issabel5_resolve_addpkgs boguskey
  '

# --- resolução de --addpkgs (issabel4) ------------------------------------------------------
out=$(netinstall::_issabel4_resolve_addpkgs callcenter licensed)
assert_eq 'issabel4: callcenter+licensed resolve pros pacotes reais (um por linha)' \
  "$(printf '%s\n' issabel-callcenter issabel-license webconsole issabel-wizard \
    issabel-packet_capture issabel-upnpc issabel-two_factor_auth issabel-theme_designer issabel-network-agent)" \
  "$out"

# --- regressão: --astver NÃO pode ter --default, senão o seletor interativo nunca dispara -----
# Achado de verdade: `flag::get astver ''` devolve o --default configurado na declaração da
# flag ANTES de olhar pro fallback ('') — um `--default 18` fazia `flag::get` sempre devolver
# "18", fazendo `[[ -z $astver ]]` (em run_issabel5/run_issabel4) nunca ser verdadeiro, matando
# pra sempre o `tui::select` de Asterisk 16/18, mesmo sem --astver na linha de comando. Testa
# a MESMA declaração usada em issabel5.sh (enum, --short a, sem --default).
flag::reset
flag::add_standard
netinstall::flags_shared
flag::add astver --type enum --enum '16|18' --short a --help 'versão do Asterisk a instalar'
flag::parse >/dev/null 2>&1
assert_eq 'astver sem --default: flag::get devolve vazio quando --astver não foi passado (permite perguntar)' \
  '' "$(flag::get astver '')"

flag::reset
flag::add_standard
netinstall::flags_shared
flag::add astver --type enum --enum '16|18' --short a --help 'versão do Asterisk a instalar'
flag::parse --astver 18 >/dev/null 2>&1
assert_eq 'astver: --astver 18 explícito continua funcionando normalmente' \
  '18' "$(flag::get astver '')"

flag::reset
flag::add_standard
netinstall::flags_shared
flag::add astver --type enum --enum '16|18' --short a --help 'versão do Asterisk a instalar'
flag::parse -a 18 >/dev/null 2>&1
assert_eq 'astver: -a (short) funciona igual --astver' \
  '18' "$(flag::get astver '')"

# --- substituição do placeholder $ASTVER -----------------------------------------------------
tmp_list=$(pvx::tmpdir)/pkgs.txt
printf 'asterisk$ASTVER\nasterisk$ASTVER-devel\nhttpd\n' >"$tmp_list"
out=$(netinstall::render_astver_placeholder "$tmp_list" 18)
assert_eq 'render_astver_placeholder substitui $ASTVER literal pelo valor' \
  "$(printf 'asterisk18\nasterisk18-devel\nhttpd')" "$out"

# --- _mem_total_kb: soma MemTotal+SwapTotal de um /proc/meminfo-like ------------------------
mem_fixture=$(pvx::tmpdir)/meminfo-fake
cat >"$mem_fixture" <<'EOF'
MemTotal:        1998432 kB
MemFree:          123456 kB
SwapTotal:        524284 kB
SwapFree:         524284 kB
EOF
assert_eq '_mem_total_kb soma MemTotal + SwapTotal (KB)' \
  "$((1998432 + 524284))" "$(netinstall::_mem_total_kb "$mem_fixture")"
assert_eq '_mem_total_kb devolve 0 se o arquivo não existir (nunca bloqueia por um sinal que não existe)' \
  '0' "$(netinstall::_mem_total_kb "$(pvx::tmpdir)/nao-existe-meminfo")"

# --- catálogo: ssh-hardening está registrado pro issabel5, default ON -------------------------
if netinstall::_tweaks_catalog | grep -q '^ssh-hardening	issabel5	1	'; then
  printf '  ok - catálogo registra ssh-hardening pro issabel5, default ON\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - catálogo deveria ter uma linha ssh-hardening/issabel5/1/...\n' >&2
  _FAIL=$((_FAIL + 1))
fi

# --- ssh_validate_pubkey ------------------------------------------------------------------------
assert_rc 'ssh_validate_pubkey: aceita ssh-ed25519 válida' 0 \
  netinstall::ssh_validate_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIENL7w74yOns+ql0/Ynt/jrpOP+vCc5jN0fHLWEzkRx9 claude-code-vps'
assert_rc 'ssh_validate_pubkey: aceita ssh-rsa válida' 0 \
  netinstall::ssh_validate_pubkey 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 comentario'
assert_rc 'ssh_validate_pubkey: aceita ecdsa-sha2-nistp256 válida' 0 \
  netinstall::ssh_validate_pubkey 'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY='
assert_rc 'ssh_validate_pubkey: aceita sem comentário' 0 \
  netinstall::ssh_validate_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIENL7w=='
assert_rc 'ssh_validate_pubkey: rejeita string vazia' 1 \
  netinstall::ssh_validate_pubkey ''
assert_rc 'ssh_validate_pubkey: rejeita texto solto' 1 \
  netinstall::ssh_validate_pubkey 'isso não é uma chave'
assert_rc 'ssh_validate_pubkey: rejeita chave privada (prefixo errado)' 1 \
  netinstall::ssh_validate_pubkey '-----BEGIN OPENSSH PRIVATE KEY-----'

# --- sshd_config_upsert -----------------------------------------------------------------------
sshd_fixture=$(pvx::tmpdir)/sshd_config-fixture
cat >"$sshd_fixture" <<'EOF'
#Port 22
#PermitRootLogin prohibit-password
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

netinstall::sshd_config_upsert "$sshd_fixture" Port 21122
assert_eq 'sshd_config_upsert: acrescenta a diretiva quando só existe comentada' \
  'Port 21122' "$(grep -E '^Port ' "$sshd_fixture" | tail -n1)"

netinstall::sshd_config_upsert "$sshd_fixture" Port 21122
assert_eq 'sshd_config_upsert: rodar de novo com o mesmo valor não duplica' \
  '1' "$(grep -cE '^Port ' "$sshd_fixture")"

netinstall::sshd_config_upsert "$sshd_fixture" Port 2222
assert_eq 'sshd_config_upsert: trocar o valor comenta a antiga e acrescenta a nova' \
  'Port 2222' "$(grep -E '^Port ' "$sshd_fixture" | tail -n1)"
assert_eq 'sshd_config_upsert: a linha antiga fica comentada, não apagada' \
  '1' "$(grep -c 'disabled.*Port 21122' "$sshd_fixture")"

netinstall::sshd_config_upsert "$sshd_fixture" PermitRootLogin no
assert_eq 'sshd_config_upsert: funciona pra outra diretiva (PermitRootLogin)' \
  'PermitRootLogin no' "$(grep -E '^PermitRootLogin ' "$sshd_fixture" | tail -n1)"

assert_rc 'sshd_config_upsert: erro se o arquivo não existe/não é gravável' 1 \
  netinstall::sshd_config_upsert "$(pvx::tmpdir)/nao-existe-sshd-config" Port 22

# --- install_packages: tenta a lista inteira num único dnf install ----------------------------
# Grava a chamada num arquivo, não num array: `out=$(...)` roda install_packages numa subshell,
# e mutações de array feitas ali dentro (via os::pkg_install) não voltam pro shell principal —
# um arquivo sobrevive à subshell.
install_calls_file=$(pvx::tmpdir)/install-calls.txt
: >"$install_calls_file"
os::pkg_install() {
  printf '%s\n' "$*" >>"$install_calls_file"
  return 0
}
out=$(netinstall::install_packages 'grupo ok' pkg-a pkg-b pkg-c 2>&1)
unset -f os::pkg_install

assert_eq 'install_packages: chama os::pkg_install UMA vez só, com a lista inteira' \
  'pkg-a pkg-b pkg-c' "$(cat "$install_calls_file")"

out_empty=$(netinstall::install_packages 'grupo vazio' 2>&1)
assert_eq 'install_packages: lista vazia não chama nada nem loga nada' '' "$out_empty"

# --- lote falha (ex: um nome de pacote não existe mais no repo) --> cai pra pacote a pacote, ---
# --- isola só o problemático, NUNCA aborta o processo ------------------------------------------
os::pkg_install() {
  (( $# > 1 )) && return 1
  [[ $1 == breaks ]] && return 1
  return 0
}
install_rc=0
out=$(netinstall::install_packages 'grupo com 1 problema' pkg-a breaks pkg-c 2>&1) || install_rc=$?
unset -f os::pkg_install

assert_eq 'install_packages: nunca aborta o processo, mesmo com pacote(s) inexistente(s)' \
  0 "$install_rc"
if [[ $out == *'lote'*'falhou'* ]]; then
  printf '  ok - install_packages avisa quando o lote falha e cai pra pacote a pacote\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - install_packages deveria avisar sobre a queda pra pacote a pacote: [%s]\n' "$out" >&2
  _FAIL=$((_FAIL + 1))
fi
if [[ $out == *'1 de 3 pacotes'*'breaks'* ]]; then
  printf '  ok - install_packages reporta exatamente qual pacote não instalou\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - install_packages deveria reportar "breaks" como o único pacote que falhou: [%s]\n' "$out" >&2
  _FAIL=$((_FAIL + 1))
fi

# --- run_issabel5: dispatch pvx (padrão) vs --legacy (raw), sem tocar em git/rede de verdade ---
# Mocka os dois fluxos de verdade (_issabel5_raw/_issabel5_custom) só pra provar o ROTEAMENTO
# — a lógica de cada um já é testada/smoke-testada em outro lugar (ver README.md).
netinstall::_issabel5_raw() { printf 'raw:%s\n' "$*"; }
netinstall::_issabel5_custom() { printf 'custom:%s\n' "$*"; }

out=$(netinstall::run_issabel5 --no-tmux)
assert_eq 'run_issabel5 sem --legacy: roteia pro fluxo pvx (padrão)' 'custom:--no-tmux' "$out"

out=$(netinstall::run_issabel5 --legacy --astver 18)
assert_eq 'run_issabel5 com --legacy: roteia pro fluxo raw, repassando os args' \
  'raw:--legacy --astver 18' "$out"

out=$(netinstall::run_issabel5 --help)
if [[ $out == *'custom:--help'* ]]; then
  printf '  ok - run_issabel5 --help (sem --legacy): cai pro fluxo pvx (padrão)\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - run_issabel5 --help deveria cair pro fluxo pvx: [%s]\n' "$out" >&2
  _FAIL=$((_FAIL + 1))
fi

out=$(netinstall::run_issabel5 --legacy --help)
if [[ $out == *'baixa e executa o instalador raw'* ]]; then
  printf '  ok - run_issabel5 --legacy --help: mostra o uso mínimo do modo raw\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - run_issabel5 --legacy --help deveria mostrar o uso do modo raw: [%s]\n' "$out" >&2
  _FAIL=$((_FAIL + 1))
fi

unset -f netinstall::_issabel5_raw netinstall::_issabel5_custom

# --- geração de senha --------------------------------------------------------------------------
pw1=$(netinstall::gen_password)
pw2=$(netinstall::gen_password)
if [[ -n $pw1 && ${#pw1} -ge 16 ]]; then
  printf '  ok - gen_password gera algo não-vazio e razoavelmente longo (%d chars)\n' "${#pw1}"
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - gen_password devolveu algo vazio ou curto demais: [%s]\n' "$pw1" >&2
  _FAIL=$((_FAIL + 1))
fi
if [[ $pw1 != "$pw2" ]]; then
  printf '  ok - gen_password não repete a mesma senha entre chamadas\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - duas chamadas de gen_password devolveram a mesma senha: [%s]\n' "$pw1" >&2
  _FAIL=$((_FAIL + 1))
fi

# --- save_credentials: pares extra key=value opcionais, sem quebrar a chamada de 3 args --------
export PVX_MODULE_STATE_DIR=$(pvx::tmpdir)/state-test
cred_file=$(netinstall::save_credentials teste sqlpw123 webpw456)
assert_eq 'save_credentials: chamada com 3 args (sem extra) continua funcionando' \
  '0' "$(grep -c '^ssh_' "$cred_file")"

cred_file2=$(netinstall::save_credentials teste sqlpw123 webpw456 'ssh_user=phonevox' 'ssh_port=21122')
assert_eq 'save_credentials: primeiro par extra aparece no arquivo' \
  '1' "$(grep -c '^ssh_user=phonevox$' "$cred_file2")"
assert_eq 'save_credentials: segundo par extra também aparece' \
  '1' "$(grep -c '^ssh_port=21122$' "$cred_file2")"
assert_eq 'save_credentials: campos originais continuam presentes com extras' \
  '1' "$(grep -c '^mysql_root_password=sqlpw123$' "$cred_file2")"

# --- print_summary: 5º parâmetro opcional aparece só quando não-vazio -------------------------
out=$(netinstall::print_summary issabel5 18 nenhum ssh-hardening 2>&1 >/dev/null)
assert_eq 'print_summary: chamada de 4 args (sem extra) continua funcionando' \
  '0' "$(printf '%s' "$out" | grep -c 'Porta SSH')"

out2=$(netinstall::print_summary issabel5 18 nenhum ssh-hardening $'  Porta SSH: 21122' 2>&1 >/dev/null)
assert_eq 'print_summary: extra não-vazio aparece no resumo' \
  '1' "$(printf '%s' "$out2" | grep -c 'Porta SSH: 21122')"

# --- ssh_hardening_ask: caminho 100% via flags (determinístico, sem TTY) -----------------------
ssh_hardening_ask_vars() {
  # roda ssh_hardening_ask isolado e imprime as SSH_HARDEN_* pra fora (subshell — só leitura).
  # USER_PW_SET (0|1), não o tamanho: netinstall::gen_password tem tamanho VARIÁVEL entre
  # chamadas (confirmado: uma chamada real deu 19 chars, não sempre 24) — comparar tamanho
  # exato flakaria.
  local SSH_HARDEN_LOCK_ROOT SSH_HARDEN_ROOT_PASSWORD SSH_HARDEN_CREATE_USER SSH_HARDEN_USERNAME \
    SSH_HARDEN_PUBKEY SSH_HARDEN_ALLOW_PASSWORD SSH_HARDEN_USER_PASSWORD SSH_HARDEN_CHANGE_PORT \
    SSH_HARDEN_PORT
  netinstall::ssh_hardening_ask 0
  local user_pw_set=0
  [[ -n $SSH_HARDEN_USER_PASSWORD ]] && user_pw_set=1
  printf 'LOCK_ROOT=%s ROOT_PW=%s CREATE_USER=%s USERNAME=%s PUBKEY=%s ALLOW_PW=%s USER_PW_SET=%s CHANGE_PORT=%s PORT=%s\n' \
    "$SSH_HARDEN_LOCK_ROOT" "$SSH_HARDEN_ROOT_PASSWORD" "$SSH_HARDEN_CREATE_USER" "$SSH_HARDEN_USERNAME" \
    "$SSH_HARDEN_PUBKEY" "$SSH_HARDEN_ALLOW_PASSWORD" "$user_pw_set" "$SSH_HARDEN_CHANGE_PORT" "$SSH_HARDEN_PORT"
}

flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse >/dev/null 2>&1
out=$(ssh_hardening_ask_vars)
assert_eq 'ssh_hardening_ask: sem TTY e sem NENHUMA flag --tweak-ssh-*, tudo fica desligado (0)' \
  'LOCK_ROOT=0 ROOT_PW= CREATE_USER=0 USERNAME= PUBKEY= ALLOW_PW=0 USER_PW_SET=0 CHANGE_PORT=0 PORT=' "$out"

flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse --tweak-ssh-lock-root --tweak-ssh-root-password 'senha123' \
  --tweak-ssh-create-user --tweak-ssh-username phonevox \
  --tweak-ssh-pubkey 'ssh-ed25519 AAAAtest x' \
  --tweak-ssh-allow-password --tweak-ssh-change-port --tweak-ssh-port 2222 >/dev/null 2>&1
out=$(ssh_hardening_ask_vars)
assert_eq 'ssh_hardening_ask: com flags explícitas, resolve tudo sem perguntar (senha custom)' \
  'LOCK_ROOT=1 ROOT_PW=senha123 CREATE_USER=1 USERNAME=phonevox PUBKEY=ssh-ed25519 AAAAtest x ALLOW_PW=1 USER_PW_SET=1 CHANGE_PORT=1 PORT=2222' "$out"

# NOTA: passa --tweak-ssh-pubkey mesmo só querendo testar --tweak-ssh-lock-root — create-user
# também cai no próprio default (1) por não ter flag própria, e default 1 exige pubkey (mesma
# regra de sempre); omitir a flag aqui faria a função sair com PVX_EXIT_USAGE, não com o
# resultado esperado abaixo.
flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse --tweak-ssh-lock-root --tweak-ssh-pubkey 'ssh-ed25519 AAAAtest x' >/dev/null 2>&1
out=$(ssh_hardening_ask_vars)
assert_eq 'ssh_hardening_ask: 1 flag dada ativa "resolve com defaults" pros itens sem flag própria' \
  'LOCK_ROOT=1 ROOT_PW=phonevox@@ CREATE_USER=1 USERNAME=phonevox PUBKEY=ssh-ed25519 AAAAtest x ALLOW_PW=0 USER_PW_SET=0 CHANGE_PORT=1 PORT=21122' "$out"

# --- ssh_hardening_ask: create_user=1 sem --tweak-ssh-pubkey e sem TTY = erro claro ------------
flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse --tweak-ssh-create-user >/dev/null 2>&1
assert_rc 'ssh_hardening_ask: create_user sem --tweak-ssh-pubkey e sem TTY sai com PVX_EXIT_USAGE' \
  "$PVX_EXIT_USAGE" bash -c '
    source "$PVX_LIB_DIR/bootstrap.sh"
    pvx::require color log os exec tui flags net
    color::init; log::init
    source "$PVX_MODULE_DIR/lib/common.sh"
    flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
    flag::parse --tweak-ssh-create-user
    local SSH_HARDEN_LOCK_ROOT SSH_HARDEN_ROOT_PASSWORD SSH_HARDEN_CREATE_USER SSH_HARDEN_USERNAME \
      SSH_HARDEN_PUBKEY SSH_HARDEN_ALLOW_PASSWORD SSH_HARDEN_USER_PASSWORD SSH_HARDEN_CHANGE_PORT \
      SSH_HARDEN_PORT
    netinstall::ssh_hardening_ask 0
  '

# --- ssh_hardening_ask: username/porta inválidos são rejeitados mesmo vindo de flag ------------
flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse --tweak-ssh-username '../etc/passwd' --tweak-ssh-pubkey 'ssh-ed25519 AAAA x' >/dev/null 2>&1
assert_rc 'ssh_hardening_ask: --tweak-ssh-username inválido sai com PVX_EXIT_USAGE' \
  "$PVX_EXIT_USAGE" bash -c '
    source "$PVX_LIB_DIR/bootstrap.sh"
    pvx::require color log os exec tui flags net
    color::init; log::init
    source "$PVX_MODULE_DIR/lib/common.sh"
    flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
    flag::parse --tweak-ssh-username "../etc/passwd" --tweak-ssh-pubkey "ssh-ed25519 AAAA x"
    local SSH_HARDEN_LOCK_ROOT SSH_HARDEN_ROOT_PASSWORD SSH_HARDEN_CREATE_USER SSH_HARDEN_USERNAME \
      SSH_HARDEN_PUBKEY SSH_HARDEN_ALLOW_PASSWORD SSH_HARDEN_USER_PASSWORD SSH_HARDEN_CHANGE_PORT \
      SSH_HARDEN_PORT
    netinstall::ssh_hardening_ask 0
  '

flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
flag::parse --tweak-ssh-port 999999 --tweak-ssh-pubkey 'ssh-ed25519 AAAA x' >/dev/null 2>&1
# --tweak-ssh-pubkey precisa vir junto: create-user cai no próprio default (1) por não ter
# flag própria, e SEM pubkey a função já sairia com PVX_EXIT_USAGE antes de chegar na
# validação de porta — "passaria" pelo motivo errado, sem nunca exercitar o código de porta.
assert_rc 'ssh_hardening_ask: --tweak-ssh-port fora do range 1-65535 sai com PVX_EXIT_USAGE' \
  "$PVX_EXIT_USAGE" bash -c '
    source "$PVX_LIB_DIR/bootstrap.sh"
    pvx::require color log os exec tui flags net
    color::init; log::init
    source "$PVX_MODULE_DIR/lib/common.sh"
    flag::reset; flag::add_standard; netinstall::flags_shared; netinstall::ssh_hardening_flags
    flag::parse --tweak-ssh-port 999999 --tweak-ssh-pubkey "ssh-ed25519 AAAA x"
    local SSH_HARDEN_LOCK_ROOT SSH_HARDEN_ROOT_PASSWORD SSH_HARDEN_CREATE_USER SSH_HARDEN_USERNAME \
      SSH_HARDEN_PUBKEY SSH_HARDEN_ALLOW_PASSWORD SSH_HARDEN_USER_PASSWORD SSH_HARDEN_CHANGE_PORT \
      SSH_HARDEN_PORT
    netinstall::ssh_hardening_ask 0
  '
unset -f ssh_hardening_ask_vars

# --- ssh_hardening_apply: mocks de useradd/usermod/chpasswd/id/getent/sshd, tudo em tmpdir -----
SSH_APPLY_CALLS=$(pvx::tmpdir)/ssh-apply-calls.txt
FAKE_HOME=$(pvx::tmpdir)/fake-home-phonevox
useradd() { printf 'useradd:%s\n' "$*" >>"$SSH_APPLY_CALLS"; }
usermod() { printf 'usermod:%s\n' "$*" >>"$SSH_APPLY_CALLS"; }
chpasswd() { printf 'chpasswd\n' >>"$SSH_APPLY_CALLS"; }
id() { return 1; }
getent() { printf 'x:x:1000:1000:x:%s:/bin/bash\n' "$FAKE_HOME"; }
sshd() { return 0; }
chown() { :; }  # evita "invalid user" tentando chown pra um usuário phonevox que não existe de verdade
export -f useradd usermod chpasswd id getent sshd chown

: >"$SSH_APPLY_CALLS"
netinstall::ssh_hardening_apply 0 '' 0 '' '' 0 '' 0 '' "$(pvx::tmpdir)/sshd-noop.conf"
assert_eq 'ssh_hardening_apply: com os 3 desligados, não chama nada e não toca no sshd_config' \
  '' "$(cat "$SSH_APPLY_CALLS")"

: >"$SSH_APPLY_CALLS"
apply_sshd=$(pvx::tmpdir)/sshd-apply.conf
printf '#PermitRootLogin prohibit-password\n#Port 22\n' >"$apply_sshd"
netinstall::ssh_hardening_apply 1 rootpw123 1 phonevox 'ssh-ed25519 AAAA test' 1 userpw456 1 21122 "$apply_sshd"

assert_eq 'ssh_hardening_apply: cria o usuário quando id() diz que não existe' \
  '1' "$(grep -c '^useradd:' "$SSH_APPLY_CALLS")"
assert_eq 'ssh_hardening_apply: chpasswd chamado 2x (root + usuário, allow_pw=1)' \
  '2' "$(grep -c '^chpasswd$' "$SSH_APPLY_CALLS")"
assert_eq 'ssh_hardening_apply: PermitRootLogin no aplicado' \
  'PermitRootLogin no' "$(grep -E '^PermitRootLogin ' "$apply_sshd" | tail -n1)"
assert_eq 'ssh_hardening_apply: Port 21122 aplicado' \
  'Port 21122' "$(grep -E '^Port ' "$apply_sshd" | tail -n1)"
assert_eq 'ssh_hardening_apply: chave pública acrescentada ao authorized_keys' \
  '1' "$(grep -c 'ssh-ed25519 AAAA test' "$FAKE_HOME/.ssh/authorized_keys" 2>/dev/null || printf 0)"

# idempotência: rodar de novo (usuário "já existe" agora) não duplica a chave nem chama useradd
: >"$SSH_APPLY_CALLS"
id() { return 0; }
netinstall::ssh_hardening_apply 1 rootpw123 1 phonevox 'ssh-ed25519 AAAA test' 1 userpw456 1 21122 "$apply_sshd"
assert_eq 'ssh_hardening_apply: rodar de novo (usuário já existe) não chama useradd de novo' \
  '0' "$(grep -c '^useradd:' "$SSH_APPLY_CALLS")"
assert_eq 'ssh_hardening_apply: rodar de novo não duplica a chave no authorized_keys' \
  '1' "$(grep -c 'ssh-ed25519 AAAA test' "$FAKE_HOME/.ssh/authorized_keys")"

# sshd -t falha => restaura o backup, não deixa o sshd_config quebrado no lugar
: >"$SSH_APPLY_CALLS"
sshd() { return 1; }
apply_sshd_bad=$(pvx::tmpdir)/sshd-apply-bad.conf
printf '#Port 22\n' >"$apply_sshd_bad"
netinstall::ssh_hardening_apply 0 '' 0 '' '' 0 '' 1 21122 "$apply_sshd_bad"
assert_eq 'ssh_hardening_apply: sshd -t falhando restaura o backup (Port volta a não estar ativo)' \
  '0' "$(grep -cE '^Port 21122' "$apply_sshd_bad")"

unset -f useradd usermod chpasswd id getent sshd chown

# --- ask_password: sem TTY (caso deste próprio runner de testes) nunca trava, sempre devolve ---
# --- algo pronto pra uso, e nunca escreve o valor gerado em stdout misturado com o prompt ------
# NOTA: isto NÃO cobre a exibição de verdade (tui::password, título/breadcrumb + leitura
# mascarada) — aquilo só se manifesta com um /dev/tty de verdade, que este ambiente de teste
# não tem (nem o sandbox do Claude tem: "/dev/tty: Device not configured"). Precisa ser
# conferido manualmente no container/VPS real (ver README.md).
ask_pw_out=$(netinstall::ask_password 'breadcrumb de teste' 'senha de teste' </dev/null 2>/dev/null)
if [[ -n $ask_pw_out && ${#ask_pw_out} -ge 16 ]]; then
  printf '  ok - ask_password sem TTY devolve uma senha gerada, não trava\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - ask_password sem TTY deveria devolver uma senha gerada: [%s]\n' "$ask_pw_out" >&2
  _FAIL=$((_FAIL + 1))
fi

# --- setenforce só roda se SELinux não estiver disabled já (evita rc=1 garantido nesse caso —
# achado de verdade numa VPS onde "setenforce 0" sempre falha porque já está disabled) --------
os::selinux_state() { printf 'enforcing'; }
PVX_DRY_RUN=1
enforcing_out=$(netinstall::_issabel5_prepare_system 2>&1)
os::selinux_state() { printf 'disabled'; }
disabled_out=$(netinstall::_issabel5_prepare_system 2>&1)
post_out=$(netinstall::_issabel5_post_install 2>&1)
PVX_DRY_RUN=0
unset -f os::selinux_state

if [[ $enforcing_out == *setenforce* ]]; then
  printf '  ok - _prepare_system chama setenforce quando SELinux não está disabled ainda\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - _prepare_system deveria chamar setenforce quando enforcing/permissive\n' >&2
  _FAIL=$((_FAIL + 1))
fi
if [[ $disabled_out != *setenforce* ]]; then
  printf '  ok - _prepare_system pula setenforce quando SELinux já está disabled\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - _prepare_system chamou setenforce mesmo já disabled (sempre falha com rc=1 nesse caso)\n' >&2
  _FAIL=$((_FAIL + 1))
fi
if [[ $post_out != *extensions_custom.conf.sample* ]]; then
  printf '  ok - _post_install pula o mv de extensions_custom.conf.sample quando o arquivo não existe (idempotente)\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - _post_install tentou mv de extensions_custom.conf.sample sem checar se existe: [%s]\n' "$post_out" >&2
  _FAIL=$((_FAIL + 1))
fi
if [[ $post_out != *setenforce* ]]; then
  printf '  ok - _post_install não repete a desabilitação de SELinux (já feita em prepare_system)\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - _post_install voltou a chamar setenforce (duplicação reintroduzida)\n' >&2
  _FAIL=$((_FAIL + 1))
fi

printf '\n%d/%d testes passaram\n' "$_PASS" "$((_PASS + _FAIL))"
((_FAIL == 0))
