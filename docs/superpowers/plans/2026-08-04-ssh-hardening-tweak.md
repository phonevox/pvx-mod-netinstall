# Tweak ssh-hardening (issabel5) — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar a tweak `ssh-hardening` (issabel5): bloqueia SSH do root, cria usuário
dedicado com sudo+chave, e troca a porta SSH — com wizard próprio (3 perguntas) e aplicação
segura (só entra em vigor no reboot final do netinstall).

**Architecture:** Lógica genérica (validação, upsert de sshd_config, wizard, apply) em
`lib/common.sh` — reutilizável por outros produtos depois. Fiação específica do issabel5
(gating pela tweak, ordem de chamada, confirmação extra, resumo, credenciais) em
`lib/issabel5.sh`. Ver spec completo:
`docs/superpowers/specs/2026-08-04-ssh-hardening-tweak-design.md`.

**Tech Stack:** Bash (mesmo padrão do resto do módulo: `run`/`srun` de `lib/exec.sh`,
`tui::select`/`tui::input`/`tui::password` de `lib/tui.sh`, `flag::add`/`flag::get` de
`lib/flags.sh`, todos do core `pvxcli`, carregados via `PVX_LIB_DIR`).

## Global Constraints

- Comentários no código: curtos (1-3 linhas), só o "porquê" quando não for óbvio — sem blocos
  longos explicando o óbvio (pedido explícito do usuário nesta sessão).
- Nenhuma mudança de SSH entra em vigor DURANTE a instalação — só escreve arquivos; ativa só no
  reboot final (`netinstall::_issabel5_finish`).
- Sem TTY e sem NENHUMA flag `--tweak-ssh-*`: os 3 sub-itens ficam desligados (0), mesmo com a
  tweak default ON no catálogo — nunca herda silenciosamente um default de alto risco em
  automação que não conhece esta flag.
- Testes automatizados (`tests/unit.sh`, mini-framework próprio do módulo — não usa
  `tests/lib/assert.sh` do core, repos separados) cobrem toda a lógica pura/determinística
  (validação, upsert de arquivo, resolução de flags, gating). Mutação real de sistema
  (`useradd`, `chpasswd`, `sshd -t` de verdade) é coberta por mock nos testes + verificação
  manual numa VPS descartável (sem automação — não existe container de teste pronto pra este
  módulo hoje).
- Rodar os testes: `PVX_ROOT=<checkout do pvxcli> bash tests/unit.sh` (de dentro de
  `modules/netinstall`). Numa checkout aninhada como este repo, `PVX_ROOT` é o diretório pai de
  `modules/`.

---

### Task 1: Catálogo — registrar a tweak `ssh-hardening`

**Files:**
- Modify: `lib/common.sh` (`netinstall::_tweaks_catalog`)
- Test: `tests/unit.sh`

**Interfaces:**
- Produces: linha `ssh-hardening	issabel5	1	<label>` no catálogo, consumida por
  `netinstall::phonevox_tweaks_menu` (já existe, sem mudança nela).

- [ ] **Step 1: Escrever o teste (vai falhar — a linha ainda não existe)**

Adicionar em `tests/unit.sh`, depois do bloco `_mem_total_kb`:

```bash
# --- catálogo: ssh-hardening está registrado pro issabel5, default ON -------------------------
if netinstall::_tweaks_catalog | grep -q '^ssh-hardening	issabel5	1	'; then
  printf '  ok - catálogo registra ssh-hardening pro issabel5, default ON\n'
  _PASS=$((_PASS + 1))
else
  printf '  FALHOU - catálogo deveria ter uma linha ssh-hardening/issabel5/1/...\n' >&2
  _FAIL=$((_FAIL + 1))
fi
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -A1 'ssh-hardening'`
Expected: `FALHOU - catálogo deveria ter uma linha...`

- [ ] **Step 3: Adicionar a linha no catálogo**

Em `lib/common.sh`, dentro de `netinstall::_tweaks_catalog`:

```bash
netinstall::_tweaks_catalog() {
  cat <<'EOF'
operator-panel	issabel5	1	Painel do operador (control_panel — visão de recepção/switchboard)
ssh-hardening	issabel5	1	Hardening de acesso SSH (bloqueia root, cria usuário admin dedicado, muda porta)
EOF
}
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -A1 'ssh-hardening'`
Expected: `ok - catálogo registra ssh-hardening...`

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: registra a tweak ssh-hardening no catálogo (issabel5, default ON)"
```

---

### Task 2: `netinstall::ssh_validate_pubkey`

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Produces: `netinstall::ssh_validate_pubkey <linha>` → rc 0 (válida) / 1 (inválida). Consumida
  pelo Task 6 (wizard) e Task 7 (apply, defensivamente).

- [ ] **Step 1: Escrever os testes (falham — a função não existe)**

Adicionar em `tests/unit.sh`, depois do bloco do catálogo:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i pubkey`
Expected: todas as linhas `FALHOU` (função inexistente → rc 127, nunca 0/1).

- [ ] **Step 3: Implementar**

Em `lib/common.sh`, logo depois de `netinstall::gen_password`:

```bash
# netinstall::ssh_validate_pubkey <linha> — só valida o FORMATO (tipo + base64 + comentário
# opcional), não a chave em si.
netinstall::ssh_validate_pubkey() {
  local line=$1
  [[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i pubkey`
Expected: todas `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: netinstall::ssh_validate_pubkey — valida formato de chave SSH pública"
```

---

### Task 3: `netinstall::sshd_config_upsert`

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Produces: `netinstall::sshd_config_upsert <arquivo> <diretiva> <valor>` → rc 0 (aplicado ou
  já estava certo) / 1 (arquivo não existe/não é gravável). Mutação idempotente: comenta
  qualquer linha ativa existente da diretiva e garante uma única linha canônica no final do
  arquivo. Consumida pelo Task 7 (apply).

- [ ] **Step 1: Escrever os testes (falham — a função não existe)**

Adicionar em `tests/unit.sh`, depois do bloco `ssh_validate_pubkey`:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i upsert`
Expected: `FALHOU` em todas (função inexistente).

- [ ] **Step 3: Implementar**

Em `lib/common.sh`, depois de `netinstall::ssh_validate_pubkey`:

```bash
# netinstall::sshd_config_upsert <arquivo> <diretiva> <valor> — garante uma linha canônica
# "<diretiva> <valor>" no final do arquivo (sshd respeita a última ocorrência ativa);
# idempotente, comenta qualquer ocorrência ativa anterior em vez de apagar.
netinstall::sshd_config_upsert() {
  local file=$1 directive=$2 value=$3
  [[ -w $file ]] || return 1

  local last_active
  last_active=$(grep -E "^[[:space:]]*${directive}[[:space:]]" "$file" | tail -n1)
  [[ $last_active == "$directive $value" ]] && return 0

  sed -i -E "s/^([[:space:]]*)(${directive}[[:space:]].*)/\1# disabled by pvx netinstall ssh-hardening: \2/" "$file"
  printf '%s %s\n' "$directive" "$value" >>"$file"
}
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i upsert`
Expected: todas `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: netinstall::sshd_config_upsert — upsert idempotente de diretiva no sshd_config"
```

---

### Task 4: `netinstall::save_credentials` — pares extra opcionais

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Consumes: nada novo.
- Produces: `netinstall::save_credentials <produto> <sql_pw> <web_pw> [extra_kv...]` — cada
  `extra_kv` é uma string `chave=valor` já formatada, escrita como linha extra no arquivo. Chamada
  com só os 3 primeiros args continua idêntica a hoje. Consumida pelo Task 8
  (`_issabel5_set_passwords`).

- [ ] **Step 1: Escrever os testes (falham — extras ainda não existem)**

Adicionar em `tests/unit.sh`, depois do bloco `gen_password`:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i save_credentials`
Expected: `FALHOU` nas duas primeiras (extras não aparecem — a função ainda ignora args extras).

- [ ] **Step 3: Implementar**

Em `lib/common.sh`, substituir `netinstall::save_credentials`:

```bash
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
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i save_credentials`
Expected: todas `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: save_credentials aceita pares extra key=value opcionais"
```

---

### Task 5: `netinstall::print_summary` — linha extra opcional

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Produces: `netinstall::print_summary <produto> <astver> <addpkgs_display> [tweaks_display]
  [extra]` — 5º parâmetro novo, opcional, impresso verbatim (uma ou mais linhas, já formatadas
  pelo chamador) só quando não-vazio. Chamadas com 3-4 args continuam idênticas a hoje.
  Consumida pelo Task 8.

- [ ] **Step 1: Escrever os testes (falham — 5º parâmetro ainda não existe)**

Adicionar em `tests/unit.sh`, depois do bloco `save_credentials`:

```bash
# --- print_summary: 5º parâmetro opcional aparece só quando não-vazio -------------------------
out=$(netinstall::print_summary issabel5 18 nenhum ssh-hardening 2>&1 >/dev/null)
assert_eq 'print_summary: chamada de 4 args (sem extra) continua funcionando' \
  '0' "$(printf '%s' "$out" | grep -c 'Porta SSH')"

out2=$(netinstall::print_summary issabel5 18 nenhum ssh-hardening $'  Porta SSH: 21122' 2>&1 >/dev/null)
assert_eq 'print_summary: extra não-vazio aparece no resumo' \
  '1' "$(printf '%s' "$out2" | grep -c 'Porta SSH: 21122')"
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i 'print_summary'`
Expected: a segunda `FALHOU` (extra ainda é ignorado).

- [ ] **Step 3: Implementar**

Em `lib/common.sh`, em `netinstall::print_summary`, mudar a linha de parâmetros e adicionar a
impressão condicional:

```bash
netinstall::print_summary() {
  local produto=$1 astver=$2 addpkgs_display=$3 tweaks_display=${4:-nenhum} extra=${5:-}
  local tz lang
  tz=$(flag::get timezone 'America/Sao_Paulo')
  lang=$(flag::get lang pt_BR)
  printf '\n%s%s%s\n' "${PVX_C[bold]:-}" "$(tui::breadcrumb netinstall "$produto" 'resumo')" "${PVX_C[reset]:-}" >&2
  printf '  Asterisk: %s\n' "$astver" >&2
  printf '  Pacotes extras: %s\n' "$addpkgs_display" >&2
  printf '  Tweaks Phonevox: %s\n' "$tweaks_display" >&2
  printf '  Timezone: %s\n' "$tz" >&2
  printf '  Idioma: %s\n' "$lang" >&2
  printf '  Senhas (MySQL/Web): definidas\n' >&2
  [[ -n $extra ]] && printf '%s\n' "$extra" >&2
  printf '\n' >&2
}
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i 'print_summary'`
Expected: todas `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: print_summary aceita linha(s) extra opcional"
```

---

### Task 6: flags + wizard `netinstall::ssh_hardening_ask`

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Consumes: `netinstall::ssh_validate_pubkey` (Task 2), `netinstall::gen_password` (já existe),
  `flag::add`/`flag::add_secret`/`flag::has`/`flag::get`/`tui::select`/`tui::input`/`tui::password`/
  `tui::breadcrumb` (core).
- Produces:
  - `netinstall::ssh_hardening_flags` — registra as 8 flags `--tweak-ssh-*` (chamar ANTES de
    `flag::parse`).
  - `netinstall::ssh_hardening_ask <has_tty>` — popula, no escopo do CHAMADOR (mesmo idioma de
    `tweaks`/`phonevox_tweaks_menu`, nunca via `$(...)`), as variáveis:
    `SSH_HARDEN_LOCK_ROOT` (0|1), `SSH_HARDEN_ROOT_PASSWORD` (string),
    `SSH_HARDEN_CREATE_USER` (0|1), `SSH_HARDEN_USERNAME` (string), `SSH_HARDEN_PUBKEY` (string),
    `SSH_HARDEN_ALLOW_PASSWORD` (0|1), `SSH_HARDEN_USER_PASSWORD` (string),
    `SSH_HARDEN_CHANGE_PORT` (0|1), `SSH_HARDEN_PORT` (string). O chamador precisa declarar
    todas como `local` (com esses nomes exatos) antes de chamar. Consumida pelo Task 8.

- [ ] **Step 1: Escrever os testes (falham — as funções não existem)**

Adicionar em `tests/unit.sh`, depois do bloco `print_summary`:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i ssh_hardening_ask`
Expected: `FALHOU`/crash em todas (funções ainda não existem).

- [ ] **Step 3: Implementar `netinstall::ssh_hardening_flags`**

Em `lib/common.sh`, depois de `netinstall::flags_shared`:

```bash
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
  flag::add tweak-ssh-pubkey \
    --help 'ssh-hardening: chave pública SSH autorizada pro usuário dedicado'
  flag::add tweak-ssh-allow-password --type bool --default 0 \
    --help 'ssh-hardening: permite login por senha (além da chave) pro usuário dedicado'
  flag::add tweak-ssh-change-port --type bool --default 1 \
    --help 'ssh-hardening: troca a porta padrão do SSH'
  flag::add tweak-ssh-port --default 21122 \
    --help 'ssh-hardening: nova porta SSH'
}
```

- [ ] **Step 4: Implementar `netinstall::ssh_hardening_ask`**

Em `lib/common.sh`, logo depois de `netinstall::ssh_hardening_flags`:

```bash
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
  # em automação que não conhece esta flag — ver Global Constraints).
  if ((!has_tty)); then
    local f any_flag=0
    for f in tweak-ssh-lock-root tweak-ssh-root-password tweak-ssh-root-password-file \
      tweak-ssh-create-user tweak-ssh-username tweak-ssh-pubkey \
      tweak-ssh-allow-password tweak-ssh-change-port tweak-ssh-port; do
      flag::has "$f" && { any_flag=1; break; }
    done
    ((any_flag)) || return 0
  fi

  # 1. bloquear root
  if flag::has tweak-ssh-lock-root; then
    SSH_HARDEN_LOCK_ROOT=$(flag::get tweak-ssh-lock-root 1)
  elif ((has_tty)); then
    tui::select "$(tui::breadcrumb netinstall issabel5 'SSH' 'bloquear root')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_LOCK_ROOT=1
  else
    SSH_HARDEN_LOCK_ROOT=1
  fi

  if ((SSH_HARDEN_LOCK_ROOT)); then
    if flag::has tweak-ssh-root-password || flag::has tweak-ssh-root-password-file; then
      SSH_HARDEN_ROOT_PASSWORD=$(flag::get tweak-ssh-root-password)
      [[ -z $SSH_HARDEN_ROOT_PASSWORD ]] && SSH_HARDEN_ROOT_PASSWORD='phonevox@@'
    elif ((has_tty)); then
      tui::password "$(tui::breadcrumb netinstall issabel5 'SSH')" \
        'senha do root pra KVM/console (vazio = phonevox@@)'
      SSH_HARDEN_ROOT_PASSWORD=${TUI_PASSWORD:-phonevox@@}
    else
      SSH_HARDEN_ROOT_PASSWORD='phonevox@@'
    fi
    log::add_secret "$SSH_HARDEN_ROOT_PASSWORD"
  fi

  # 2. usuário dedicado
  if flag::has tweak-ssh-create-user; then
    SSH_HARDEN_CREATE_USER=$(flag::get tweak-ssh-create-user 1)
  elif ((has_tty)); then
    tui::select "$(tui::breadcrumb netinstall issabel5 'SSH' 'usuário dedicado')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_CREATE_USER=1
  else
    SSH_HARDEN_CREATE_USER=1
  fi

  if ((SSH_HARDEN_CREATE_USER)); then
    SSH_HARDEN_USERNAME=$(flag::get tweak-ssh-username phonevox)
    if ((has_tty)) && ! flag::has tweak-ssh-username; then
      tui::input 'nome do usuário dedicado' phonevox || exit "$PVX_EXIT_ABORTED"
      SSH_HARDEN_USERNAME=$TUI_INPUT
    fi
    if [[ ! $SSH_HARDEN_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      log::error 'netinstall issabel5: --tweak-ssh-username inválido (use [a-z0-9_-], começando com letra/underscore): %s' "$SSH_HARDEN_USERNAME"
      exit "$PVX_EXIT_USAGE"
    fi

    if flag::has tweak-ssh-pubkey; then
      SSH_HARDEN_PUBKEY=$(flag::get tweak-ssh-pubkey)
      if ! netinstall::ssh_validate_pubkey "$SSH_HARDEN_PUBKEY"; then
        log::error 'netinstall issabel5: --tweak-ssh-pubkey não parece uma chave pública SSH válida'
        exit "$PVX_EXIT_USAGE"
      fi
    elif ((has_tty)); then
      while true; do
        tui::input 'cole a chave pública SSH (ssh-ed25519/ssh-rsa/ecdsa-sha2-*)' '' || exit "$PVX_EXIT_ABORTED"
        netinstall::ssh_validate_pubkey "$TUI_INPUT" && { SSH_HARDEN_PUBKEY=$TUI_INPUT; break; }
        printf 'chave inválida — precisa começar com ssh-ed25519/ssh-rsa/ecdsa-sha2-*\n' >&2
      done
    else
      log::error 'netinstall issabel5: --tweak-ssh-pubkey é obrigatória sem terminal interativo (ssh-hardening + criação de usuário ativas)'
      exit "$PVX_EXIT_USAGE"
    fi

    if flag::has tweak-ssh-allow-password; then
      SSH_HARDEN_ALLOW_PASSWORD=$(flag::get tweak-ssh-allow-password 0)
    elif ((has_tty)); then
      tui::select "$(tui::breadcrumb netinstall issabel5 'SSH' 'permitir senha')" \
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
  elif ((has_tty)); then
    tui::select "$(tui::breadcrumb netinstall issabel5 'SSH' 'porta')" \
      'Sim (recomendado)' 'Não' || exit "$PVX_EXIT_ABORTED"
    [[ $TUI_CHOICE == 'Não' ]] || SSH_HARDEN_CHANGE_PORT=1
  else
    SSH_HARDEN_CHANGE_PORT=1
  fi

  if ((SSH_HARDEN_CHANGE_PORT)); then
    SSH_HARDEN_PORT=$(flag::get tweak-ssh-port 21122)
    if ((has_tty)) && ! flag::has tweak-ssh-port; then
      tui::input 'porta SSH' 21122 || exit "$PVX_EXIT_ABORTED"
      SSH_HARDEN_PORT=$TUI_INPUT
    fi
    if [[ ! $SSH_HARDEN_PORT =~ ^[0-9]+$ ]] || ((SSH_HARDEN_PORT < 1 || SSH_HARDEN_PORT > 65535)); then
      log::error 'netinstall issabel5: --tweak-ssh-port inválido (precisa ser 1-65535): %s' "$SSH_HARDEN_PORT"
      exit "$PVX_EXIT_USAGE"
    fi
  fi
}
```

- [ ] **Step 5: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i ssh_hardening_ask`
Expected: todas `ok`.

- [ ] **Step 6: Rodar a suíte inteira (garantir que nada quebrou)**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh`
Expected: só a falha pré-existente de `setenforce` (ambiente sem SELinux/Linux de verdade —
não relacionada a esta mudança); tudo mais `ok`.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: wizard ssh_hardening_ask + flags --tweak-ssh-* (issabel5)"
```

---

### Task 7: `netinstall::ssh_hardening_apply`

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/unit.sh`

**Interfaces:**
- Consumes: `netinstall::sshd_config_upsert` (Task 3), `run`/`srun` (core `lib/exec.sh`).
- Produces: `netinstall::ssh_hardening_apply <lock_root> <root_pw> <create_user> <username>
  <pubkey> <allow_pw> <user_pw> <change_port> <port> [sshd_config_path]` — 10º argumento
  opcional (default `/etc/ssh/sshd_config`), só existe pra permitir apontar pra um arquivo de
  teste. NUNCA reinicia o sshd — só escreve/valida (`sshd -t`). Consumida pelo Task 8.

- [ ] **Step 1: Escrever os testes (falham — a função não existe)**

Adicionar em `tests/unit.sh`, depois do bloco `ssh_hardening_ask`:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i ssh_hardening_apply`
Expected: `FALHOU`/crash (função inexistente).

- [ ] **Step 3: Implementar**

Em `lib/common.sh`, depois de `netinstall::ssh_hardening_ask`:

```bash
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
    run -- mkdir -m 700 -p "$ssh_dir"
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
```

- [ ] **Step 4: Rodar de novo e confirmar que passa**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh 2>&1 | grep -i ssh_hardening_apply`
Expected: todas `ok`.

- [ ] **Step 5: Rodar a suíte inteira**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh`
Expected: só a falha pré-existente de `setenforce`; tudo mais `ok`.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/unit.sh
git commit -m "feat: netinstall::ssh_hardening_apply — aplica root lock/usuário/porta, sem reiniciar sshd"
```

---

### Task 8: Fiação em `lib/issabel5.sh`

**Files:**
- Modify: `lib/issabel5.sh` (`netinstall::_issabel5_custom`, `netinstall::_issabel5_set_passwords`)
- Test: `tests/unit.sh` (gating determinístico) + verificação manual numa VPS (root
  lock/usuário/porta são mudanças reais de sistema, cobertas apenas por mock no Task 7)

**Interfaces:**
- Consumes: `netinstall::ssh_hardening_flags`/`ssh_hardening_ask`/`ssh_hardening_apply`
  (Task 6/7), `netinstall::print_summary` (Task 5), `netinstall::save_credentials` (Task 4).
- Produces: `netinstall::_issabel5_set_passwords <sql_pw> <web_pw> [extra_kv...]` — assinatura
  estendida (extra_kv repassado pra `save_credentials`); nenhum outro contrato externo novo
  (tudo mais é interno a `_issabel5_custom`).

- [ ] **Step 1: Registrar as flags e derivar o gate da tweak**

Em `lib/issabel5.sh`, dentro de `netinstall::_issabel5_custom`, logo depois de
`netinstall::flags_shared` (perto de onde as outras flags são adicionadas):

```bash
  netinstall::flags_shared
  netinstall::ssh_hardening_flags
```

Localizar o bloco que declara/deriva `tweak_operator_panel` (procure por
`for _tw in ${tweaks[@]+"${tweaks[@]}"}; do`) e SUBSTITUIR o bloco inteiro (da linha `local
tweak_operator_panel=0 _tw` até o `done` do loop) por esta versão, que já inclui a derivação da
nova tweak e a declaração das variáveis do wizard:

```bash
  local tweak_operator_panel=0 tweak_ssh_hardening=0 _tw
  for _tw in ${tweaks[@]+"${tweaks[@]}"}; do
    [[ $_tw == operator-panel ]] && tweak_operator_panel=1
    [[ $_tw == ssh-hardening ]] && tweak_ssh_hardening=1
  done

  local SSH_HARDEN_LOCK_ROOT=0 SSH_HARDEN_ROOT_PASSWORD='' SSH_HARDEN_CREATE_USER=0 \
    SSH_HARDEN_USERNAME='' SSH_HARDEN_PUBKEY='' SSH_HARDEN_ALLOW_PASSWORD=0 \
    SSH_HARDEN_USER_PASSWORD='' SSH_HARDEN_CHANGE_PORT=0 SSH_HARDEN_PORT=''
  if ((tweak_ssh_hardening)); then
    netinstall::ssh_hardening_ask "$has_tty"
  fi
```

- [ ] **Step 2: Resumo + confirmação extra**

Localizar a chamada de `netinstall::print_summary issabel5 "$astver" "$addpkgs_display"
"$tweaks_display"` e o `netinstall::confirm_destructive` logo depois. Substituir por:

```bash
  local ssh_summary=''
  if ((tweak_ssh_hardening)); then
    ((SSH_HARDEN_LOCK_ROOT)) && ssh_summary+=$'\n  SSH: root sem login SSH (senha padronizada p/ KVM)'
    ((SSH_HARDEN_CREATE_USER)) && ssh_summary+=$'\n  SSH: usuário dedicado '"$SSH_HARDEN_USERNAME"
    ((SSH_HARDEN_CHANGE_PORT)) && ssh_summary+=$'\n  SSH: porta '"$SSH_HARDEN_PORT"
  fi
  netinstall::print_summary issabel5 "$astver" "$addpkgs_display" "$tweaks_display" "$ssh_summary"

  if ! netinstall::confirm_destructive 'Prosseguir com a instalação do Issabel 5?'; then
    log::error 'netinstall issabel5: cancelado (sem confirmação)'
    exit "$PVX_EXIT_ABORTED"
  fi

  if ((tweak_ssh_hardening)) && ((SSH_HARDEN_LOCK_ROOT || SSH_HARDEN_CREATE_USER || SSH_HARDEN_CHANGE_PORT)); then
    local ssh_confirm_msg='ssh-hardening:'
    ((SSH_HARDEN_CHANGE_PORT)) && ssh_confirm_msg+=" a porta SSH vai mudar pra $SSH_HARDEN_PORT;"
    ((SSH_HARDEN_LOCK_ROOT)) && ssh_confirm_msg+=' o root não vai mais aceitar login SSH;'
    ssh_confirm_msg+=' tudo só depois do reboot final. Confirma?'
    if ! exec::confirm "$ssh_confirm_msg [s/N]" n; then
      log::error 'netinstall issabel5: cancelado (ssh-hardening não confirmado)'
      exit "$PVX_EXIT_ABORTED"
    fi
  fi
```

- [ ] **Step 3: Aplicar depois de `_issabel5_post_install`**

Localizar `netinstall::_issabel5_post_install` na sequência de chamadas de
`_issabel5_custom` e adicionar logo depois:

```bash
  netinstall::_issabel5_post_install
  if ((tweak_ssh_hardening)); then
    netinstall::ssh_hardening_apply "$SSH_HARDEN_LOCK_ROOT" "$SSH_HARDEN_ROOT_PASSWORD" \
      "$SSH_HARDEN_CREATE_USER" "$SSH_HARDEN_USERNAME" "$SSH_HARDEN_PUBKEY" \
      "$SSH_HARDEN_ALLOW_PASSWORD" "$SSH_HARDEN_USER_PASSWORD" \
      "$SSH_HARDEN_CHANGE_PORT" "$SSH_HARDEN_PORT"
  fi
  netinstall::_issabel5_install_db
```

- [ ] **Step 4: Estender `_issabel5_set_passwords` e repassar as credenciais SSH**

Em `netinstall::_issabel5_set_passwords`, mudar a assinatura:

```bash
netinstall::_issabel5_set_passwords() {
  local sql_pw=$1 web_pw=$2
  shift 2
  local -a extra_kv=("$@")
  log::info 'netinstall issabel5: definindo senhas de acesso (MySQL root / admin Web)...'

  if run --mask 3,4 -- /usr/bin/issabel-admin-passwords --cli init "$sql_pw" "$web_pw"; then
    netinstall::_issabel5_sync_fop2_manager_secret
  else
    log::warn 'netinstall issabel5: issabel-admin-passwords falhou/indisponível — rode manualmente depois'
  fi

  local cred_file
  cred_file=$(netinstall::save_credentials issabel5 "$sql_pw" "$web_pw" ${extra_kv[@]+"${extra_kv[@]}"})
  log::info 'netinstall issabel5: credenciais salvas em %s (0600) — só existem aí e nesta tela' "$cred_file"
}
```

Na chamada dela (dentro de `_issabel5_custom`, antes de `_issabel5_finish`), montar
`ssh_cred_kv` e passar:

```bash
  local -a ssh_cred_kv=()
  if ((tweak_ssh_hardening)); then
    ((SSH_HARDEN_LOCK_ROOT)) && ssh_cred_kv+=("ssh_root_password=$SSH_HARDEN_ROOT_PASSWORD")
    if ((SSH_HARDEN_CREATE_USER)); then
      ssh_cred_kv+=("ssh_user=$SSH_HARDEN_USERNAME")
      ((SSH_HARDEN_ALLOW_PASSWORD)) && ssh_cred_kv+=("ssh_user_password=$SSH_HARDEN_USER_PASSWORD")
    fi
    ((SSH_HARDEN_CHANGE_PORT)) && ssh_cred_kv+=("ssh_port=$SSH_HARDEN_PORT")
  fi
  netinstall::_issabel5_set_passwords "$sql_pw" "$web_pw" ${ssh_cred_kv[@]+"${ssh_cred_kv[@]}"}
  if ((tweak_ssh_hardening)); then
    ((SSH_HARDEN_CHANGE_PORT)) && log::warn 'netinstall issabel5: ssh-hardening — depois do reboot, reconecte na porta %s' "$SSH_HARDEN_PORT"
    ((SSH_HARDEN_CREATE_USER)) && log::warn 'netinstall issabel5: ssh-hardening — depois do reboot, use o usuário %s (chave fornecida) pra acessar' "$SSH_HARDEN_USERNAME"
    ((SSH_HARDEN_LOCK_ROOT)) && log::warn 'netinstall issabel5: ssh-hardening — depois do reboot, root só via KVM/console'
  fi
  netinstall::_issabel5_finish
```

- [ ] **Step 5: Checar sintaxe**

Run: `bash -n lib/issabel5.sh && bash -n lib/common.sh`
Expected: sem saída (sintaxe ok).

- [ ] **Step 6: Rodar a suíte inteira de novo**

Run: `PVX_ROOT=/c/Users/masutty/Desktop/work/pvxcli bash tests/unit.sh`
Expected: só a falha pré-existente de `setenforce`; tudo mais `ok` (nenhuma regressão nos
testes já existentes de `_issabel5_custom`/`run_issabel5`/etc).

- [ ] **Step 7: Verificação manual numa VPS descartável (obrigatória — mutação real de sistema)**

Sem VPS de teste automatizado pra este módulo, confirmar manualmente via SSH (mesmo processo já
usado nesta sessão pra validar o fix do FOP2/amportal):

```bash
# numa VPS Rocky 8 limpa/descartável:
pvx netinstall issabel5 --astver 18 --tweaks ssh-hardening \
  --tweak-ssh-pubkey "$(cat ~/.ssh/sua_chave.pub)" --yes --no-reboot
# antes do reboot, confirmar:
sudo sshd -t                                    # config válida
sudo cat /etc/ssh/sshd_config | grep -E '^(Port|PermitRootLogin)'
sudo cat /home/phonevox/.ssh/authorized_keys
sudo cat /var/lib/pvx/state/netinstall/credentials-issabel5-*.txt
id phonevox && groups phonevox                  # tem wheel?
# só ENTÃO reiniciar manualmente e reconectar na porta nova/usuário novo pra confirmar de verdade
sudo reboot
ssh -p 21122 phonevox@<ip>
```

Expected: config válida, usuário criado com sudo (`wheel`), chave autorizada, credenciais no
arquivo, e reconexão pós-reboot funcionando na porta/usuário novos.

- [ ] **Step 8: Commit**

```bash
git add lib/issabel5.sh
git commit -m "feat: fiação da tweak ssh-hardening no fluxo issabel5 (resumo, confirmação, apply, credenciais)"
```

---

### Task 9: Atualizar o spec com o estado final (housekeeping)

**Files:**
- Modify: `docs/superpowers/specs/2026-08-04-ssh-hardening-tweak-design.md`

- [ ] **Step 1: Marcar o spec como implementado**

No topo do arquivo, mudar `**Status:** aprovado, pronto pra plano de implementação` para
`**Status:** implementado (ver docs/superpowers/plans/2026-08-04-ssh-hardening-tweak.md)`.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-04-ssh-hardening-tweak-design.md
git commit -m "docs: marca o spec ssh-hardening como implementado"
```
