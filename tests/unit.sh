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

# --- substituição do placeholder $ASTVER -----------------------------------------------------
tmp_list=$(pvx::tmpdir)/pkgs.txt
printf 'asterisk$ASTVER\nasterisk$ASTVER-devel\nhttpd\n' >"$tmp_list"
out=$(netinstall::render_astver_placeholder "$tmp_list" 18)
assert_eq 'render_astver_placeholder substitui $ASTVER literal pelo valor' \
  "$(printf 'asterisk18\nasterisk18-devel\nhttpd')" "$out"

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

# --- SELinux só é desabilitado uma vez (prepare_system), não de novo em post_install --------
PVX_DRY_RUN=1
prepare_out=$(netinstall::_issabel5_prepare_system 2>&1)
post_out=$(netinstall::_issabel5_post_install 2>&1)
PVX_DRY_RUN=0

if [[ $prepare_out == *setenforce* ]]; then
  printf '  ok - _prepare_system desabilita SELinux\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - _prepare_system deveria desabilitar SELinux (setenforce ausente da saída)\n' >&2
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
