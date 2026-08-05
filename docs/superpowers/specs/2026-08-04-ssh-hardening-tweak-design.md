# Tweak `ssh-hardening` (issabel5) — design

**Data:** 2026-08-04
**Status:** implementado (ver docs/superpowers/plans/2026-08-04-ssh-hardening-tweak.md)

## Contexto

O netinstall issabel5 (`lib/issabel5.sh`) já tem um sistema de "Tweaks Phonevox"
(`lib/common.sh:netinstall::_tweaks_catalog` + `netinstall::phonevox_tweaks_menu`): uma
checklist genérica onde cada tweak é uma linha (chave/produto/default/label) e marcar a chave
já é a decisão inteira — sem sub-perguntas, sem estado extra. O único exemplo hoje é
`operator-panel` (instala o módulo `control_panel`).

Esta é a primeira tweak que precisa de **fluxo próprio**: depois de marcada na checklist, ela
dispara um mini-wizard de 3 perguntas (cada uma com follow-ups), ao contrário de só ligar/
desligar um passo fixo.

## O que a tweak faz

Hardening de acesso SSH em três frentes independentes, cada uma opt-in dentro do próprio
wizard:

1. **Bloquear root** — desabilita login SSH do usuário `root` e padroniza sua senha (pra acesso
   só via KVM/console físico).
2. **Usuário dedicado** — cria um usuário com sudo (grupo `wheel`), autoriza uma chave pública
   SSH fornecida, e permite (opcionalmente) login por senha além da chave.
3. **Porta SSH** — troca a porta padrão (22) por uma escolhida.

## Catálogo e escopo

- Chave: `ssh-hardening`
- Label: `Hardening de acesso SSH (bloqueia root, cria usuário admin dedicado, muda porta)`
- Escopo no catálogo: `issabel5` (só esse produto por agora — a lógica de aplicação em si é
  genérica/OS-level, sem nada específico do Issabel, então estender pro issabel4 depois é só
  adicionar `issabel4` na coluna de produtos da mesma linha do catálogo).
- Default: `1` (ON) — mesmo espírito dos sub-defaults abaixo, todos "sim" por padrão.

Continua aparecendo como UM item normal na checklist "Tweaks Phonevox" de sempre
(`netinstall::phonevox_tweaks_menu`, sem mudança nela). O que muda: depois que essa função
retorna, se `ssh-hardening` estiver em `tweaks[]`, `_issabel5_custom` chama um wizard próprio
(`netinstall::ssh_hardening_ask`, em `lib/common.sh` — genérico, não issabel5-specific) ANTES do
`print_summary`/`confirm_destructive`, na mesma fase de "pergunta tudo antes de começar" que
astver/addpkgs/senhas já respeitam. Chamada direta, nunca via `$(...)`/`< <(...)` — mesma regra
já documentada em `phonevox_tweaks_menu` (TTY real + `tui::checklist`/`tui::select` escrevem
parte da UI em stdout).

## O wizard (interativo, TTY)

```
1. limitar e padronizar acesso root? (s/n, default s)
   (desabilita login SSH do root; senha do root fica padronizada pra acesso via KVM/console)
   1.1 senha do root (default: phonevox@@, ou digite uma própria)

2. criar usuário dedicado? (s/n, default s)
   2.1 nome do usuário (default: phonevox)
   2.2 cole a chave pública SSH (valida prefixo: ssh-ed25519/ssh-rsa/ecdsa-sha2-*)
   2.3 permitir login por senha também, além da chave? (s/n, default n)
       (se sim: senha gerada aleatória — não perguntada — sai no arquivo de credenciais)

3. mudar a porta padrão do SSH? (s/n, default s)
   3.1 qual porta? (default 21122)
```

Widgets: `tui::select` (sim/não, 2 opções) pras 3 perguntas principais; `tui::input` pra
usuário/chave/porta; `tui::password` só pra senha do root (mascarada, com nota "vazio = usa o
padrão: phonevox@@" — ao contrário de `netinstall::ask_password`, aqui vazio NÃO gera senha
aleatória, cai no default fixo documentado, porque o objetivo é uma senha conhecida pra
console).

Saída: a função popula variáveis no escopo do chamador (mesmo idioma de `tweaks`/`TUI_RESULT`
já usado em `phonevox_tweaks_menu`/`tui::checklist`) — nenhuma delas passa por `$(...)`.

## Non-interativo (sem TTY) / flags

Mesmo contrato de sempre: sem TTY, cada decisão precisa vir de flag. **Exceção deliberada ao
padrão do resto do módulo:** sem TTY E sem NENHUMA flag `--tweak-ssh-*` dada, os 3 sub-itens
ficam desligados (0) — NÃO herdam o default "1" do catálogo. Diferente de `operator-panel`
(baixo risco, seguro aplicar o default sem confirmação), esta tweak muda senha de root/cria
usuário/muda porta — perigoso demais pra aplicar via um default silencioso em automação que não
sabe que esta flag passou a existir. Só fica com o default "1" e passa a EXIGIR
`--tweak-ssh-pubkey` (erro claro se faltar, aí sim mesmo padrão de `--astver`) quando pelo menos
uma flag `--tweak-ssh-*` foi dada explicitamente, OU há TTY disponível.

```
--tweak-ssh-lock-root            bool, default 1
--tweak-ssh-root-password        secret (flag/--file/env) — default: phonevox@@ (fixo, não
                                  aleatório — é senha de console/KVM, documentada de propósito)
--tweak-ssh-create-user          bool, default 1
--tweak-ssh-username             default: phonevox
--tweak-ssh-pubkey               obrigatória se create-user=1 sem TTY — chave SSH pública
--tweak-ssh-allow-password       bool, default 0 (só chave é o default seguro)
--tweak-ssh-change-port          bool, default 1
--tweak-ssh-port                 default: 21122
```

`--tweak-ssh-root-password` via `flag::add_secret` (mesmo padrão de `sql-password`/
`web-password`), mas com resolução própria (não `netinstall::resolve_secret_or_ask`, que sempre
cai em senha aleatória sem flag) — sem flag e com TTY, prompt com default fixo; sem flag e sem
TTY, usa o default fixo direto, sem perguntar.

## Aplicação (`netinstall::ssh_hardening_apply`, genérica em `lib/common.sh`)

Recebe os valores já resolvidos como argumentos explícitos (não lê variáveis globais) — mesmo
padrão de `_issabel5_set_passwords`.

**Ponto de chamada em `_issabel5_custom`:** depois de `_issabel5_post_install` (firewalld já
desativado-se-presente) e antes de `_issabel5_finish` (reboot) — mesma posição/gating de
`_issabel5_control_panel`, um `if` guardado pela variável derivada de `tweaks[]`. Só precisa
rodar depois de `_issabel5_prepare_system` (SELinux) e `_issabel5_post_install` (firewalld) por
causa do item 4 (porta) abaixo; não depende de install_db/control_panel/timezone/senhas.

**Timing — só escreve, nunca reinicia o sshd durante a instalação.** Ativa só no reboot final
já existente (`_issabel5_finish`). Zero risco de derrubar a sessão SSH do operador no meio do
netinstall.

1. **Backup** de `/etc/ssh/sshd_config` antes de qualquer edição
   (`cp --preserve ... sshd_config.bak.<timestamp>`, mesmo padrão já usado pro `php.ini`).

2. **Bloquear root** (se escolhido):
   - `chpasswd` com a senha resolvida (nunca em argv/`ps`).
   - Upsert idempotente de `PermitRootLogin no` no `sshd_config` (mesmo padrão de sed já usado
     pro `php.ini`/`sysctl.conf` no módulo: substitui a linha se existir, comentada ou não,
     senão adiciona).

3. **Usuário dedicado** (se escolhido):
   - `useradd -m -s /bin/bash <user>` (se não existir já) + `usermod -aG wheel <user>` (sudo via
     grupo `wheel`, pede senha no `sudo` — não é NOPASSWD).
   - `~/.ssh/authorized_keys` (700/600) com a chave colada.
   - Política de senha da própria conta, SEM tocar em `sshd_config` global nem em `Match User`:
     só-chave → não seta senha (conta já fica travada por padrão depois do `useradd`); permitir
     senha → `chpasswd` com senha aleatória (`netinstall::gen_password`). PAM já recusa auth por
     senha numa conta sem hash — a chave pública continua funcionando independente disso.

4. **Porta SSH** (se escolhido):
   - Upsert idempotente de `Port <n>` no `sshd_config`, mesmo padrão do item 2.
   - Depende de SELinux já desabilitado (`_issabel5_prepare_system`) e firewalld já
     desativado-se-presente (`_issabel5_post_install`) rodarem ANTES — comentário no código
     documentando essa dependência de ordem, já que sem isso precisaria de
     `semanage port`/`firewall-cmd --add-port`.

5. **Validação (rede de segurança):** depois de todas as edições, `sshd -t -f sshd_config`. Se
   falhar: restaura o backup do passo 1, `log::error` explicando que o hardening SSH NÃO foi
   aplicado (best-effort, não aborta o resto do netinstall — instalação do Issabel continua
   normal, só sem essa tweak).

6. **Confirmação extra**, além do `confirm_destructive` genérico de sempre — acontece na MESMA
   fase "pergunta tudo antes de começar", logo depois do `confirm_destructive` geral e ainda
   antes de `_issabel5_add_repos` (ou seja, antes de qualquer mudança real no sistema, não perto
   do reboot). Só dispara quando a tweak tem pelo menos uma mudança ativa, mostrando
   explicitamente o que vai mudar (porta nova, usuário novo, root sem SSH): *"A porta SSH vai
   mudar pra <N> e o root não vai mais aceitar login SSH depois do reboot. Confirma?"*. Respeita
   `PVX_ASSUME_YES`/`--yes` como `exec::confirm` já faz (nunca trava em cron/non-TTY). Recusar
   aqui cancela a instalação inteira (mesmo `exit "$PVX_EXIT_ABORTED"` do `confirm_destructive`),
   não só desliga a tweak — evitar surpresa de "instalação rodou, tweak não" sem aviso.

7. **Mensagem final** (antes do `run -- reboot` em `_issabel5_finish`) recapitulando usuário
   criado / porta nova / onde estão as credenciais salvas — pro operador não descobrir só depois
   do reboot que precisa reconectar diferente.

## Resumo e credenciais

- `netinstall::print_summary`: quando `ssh-hardening` está ativa, acrescenta linhas mostrando o
  que vai mudar (usuário, porta, root sem SSH) — visível antes da confirmação destrutiva, junto
  do resto (Asterisk/pacotes/tweaks/timezone).
- `netinstall::save_credentials`: assinatura atual (`produto, sql_pw, web_pw`) ganha pares
  extras opcionais `key=value` (sem quebrar quem já chama só com os dois primeiros). Quando
  relevante, inclui:
  ```
  ssh_root_password=...
  ssh_user=phonevox
  ssh_user_password=...        # só se "permitir senha" = sim
  ssh_port=21122                # só se a porta foi trocada
  ```
  Mesmo arquivo 0600 de sempre, mesma mensagem de "só existe aí e nesta tela".

## Fora de escopo (de propósito)

- Não toca em `PasswordAuthentication` global do sshd — a política por conta (senha travada
  vs. definida) já resolve isso sem precisar de `Match User`.
- Não afeta outros usuários existentes (ex: `rocky`, se vier de cloud-init).
- Não lida com fail2ban/jails específicas de porta — fora do escopo desta tweak.
- Sem rollback automático pós-reboot (fora do "restaura backup se `sshd -t` falhar" do passo 5)
  — reverter depois do reboot é acesso via KVM/console, do jeito que o próprio hardening prevê.
