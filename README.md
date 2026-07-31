# pvx-mod-netinstall

Módulo do [`pvx`](https://github.com/phonevox/pvxcli) — **isto não roda sozinho**. Requer
`pvx-core >= 0.1.0` instalado na máquina-alvo (o entrypoint faz `source` da lib compartilhada
do core via `$PVX_LIB_DIR`, sempre injetado pelo dispatcher do `pvx`).

## O que faz

Instala Issabel 4 ou Issabel 5 do zero numa máquina Rocky/CentOS/RHEL-like limpa e
recém-provisionada — pacotes, Asterisk, MariaDB, ajustes de SELinux/firewalld, timezone,
senhas de acesso, e reboot final.

Não existe um modo "interativo" separado de um modo "desassistido" — é sempre a mesma regra:
o que foi passado por flag não pergunta nada; o que faltou, se tem terminal, pergunta só
aquilo (uma pergunta por vez, nunca um wizard de tudo junto); sem terminal e sem flag, erro
claro dizendo o que falta. Passe todas as flags de uma vez pra rodar 100% sem interação (ex:
instalação em lote via SSH); passe só algumas e responda o resto na hora.

## Instalação

```sh
pvx modules install git@github.com:phonevox/pvx-mod-netinstall.git
```

## Uso

```sh
pvx netinstall issabel5 --astver 18
pvx netinstall issabel4 --astver 16 --addpkgs licensed --addpkgs community-blocklist \
  --sql-password-file /root/.netinstall-sql --web-password-file /root/.netinstall-web
pvx            # menu interativo: netinstall > issabel5/issabel4
```

Rode `pvx netinstall issabel5 --help` / `pvx netinstall issabel4 --help` pra ver todas as
flags (senha, timezone, idioma, `--no-tmux`, `--no-reboot`, `--force`, `--dry-run`, `--yes`).

**Atenção**: desativa SELinux/firewalld e reinicia o servidor ao final. Só rode contra uma
máquina descartável/recém-provisionada — o módulo se recusa a rodar se já detectar um
Issabel/Asterisk instalado, a menos que `--force` seja passado.

## Escopo desta versão

Só o núcleo da instalação (repositórios, pacotes, Asterisk, Issabel, senhas, timezone,
reboot). As customizações Phonevox exclusivas do `issabel4` legado (tema Falevox, módulo de
avaliação/Voxura, firewall próprio, backup engine custom, siptracer, zoxide, fix de
monitoramento/dialpatterns) ainda não foram portadas — as flags existem e avisam claramente
que não fazem nada ainda, em vez de fingir que funcionam.
