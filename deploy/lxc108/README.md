# Operação do Paperclip na LXC 108

Cópia dos scripts, crons e drop-ins de systemd que mantêm a instância da LXC 108
em ciclo contínuo. A árvore espelha os caminhos absolutos no container
(`usr/local/bin/…` → `/usr/local/bin/…`).

| Item | Função | Agenda |
|---|---|---|
| `paperclip-healthcheck` | 3 falhas seguidas de `/api/health` → `systemctl restart paperclip` + aviso; disco ≥90% | `*/5` (`etc/cron.d/paperclip-healthcheck`) |
| `paperclip-verify` | auditoria de serviços, agentes, issues, quota e d1 | `*/15` |
| `paperclip-manager` | desbloqueio validado pelo d1 (com motivo do último comentário), órfãs a cada 72h | `7,22,37,52` |
| `paperclip-deliver` | entrega de resultados | `3,18,33,48` |
| `paperclip-supervisor.sh` | supervisão geral, avisos via `paperclip-notify` | `*/10` |
| `paperclip-routine-dedupe.sh`, `paperclip-bridge-guard.sh`, `guardian-watch`, `imap-watchdog.sh` | deduplicação de rotinas, ponte Telegram, guardião, IMAP | ver `crontab-root.txt` |
| `paperclip.service.d/10-resilience.conf` | `Restart=always`, sem limite de reinícios, depois do PostgreSQL | systemd |
| `var/lib/paperclip/mail-digest/jmp30_fetch.py` | resumo dos e-mails da caixa de projetos para o CTO | `0 */2` |

## Envio de entregas (uma única vez por issue)

- `paperclip-send-mail` registra todo envio bem-sucedido em `/var/lib/paperclip-mail/sent.log`
  (`data<TAB>JMP-NNN<TAB>destinatário<TAB>anexos`), com os `[JMP-NNN]` do assunto.
- `var/lib/paperclip/tools/telegram-bridge/bridge.py` envia a entrega ao operador quando o issue
  vira `done`, mas pula o issue se o ledger já tem envio com anexo; o lote é esvaziado antes do
  envio, então falha avisa no Telegram e não reenvia em loop; nomes de projeto viram nomes de
  arquivo seguros.
- `paperclip-deliver` respeita o mesmo ledger.
- O bridge chama `paperclip-send-mail` direto, sem `sudo`: a unit roda com `NoNewPrivileges=true`,
  que bloqueia `sudo`. Requisitos: `/etc/paperclip-mail.env` root:paperclip 0640 e
  `/var/lib/paperclip-mail/` root:paperclip 2775 (ledger 0664).
- Execuções de rotina (`origin_kind = routine_execution`, ex.: triagem de e-mails) nunca geram
  entrega (regra do operador de 29/10).
- `paperclip-verify` consulta no banco issues abertos ocultos ou com dono encerrado, que a
  listagem da API não retorna.
- As instruções dos agentes (`AGENTS.md` de cada agente, fora deste repositório) dizem: fechar
  `done` após envio autorizado é seguro; envio manual leva `[JMP-NNN]` no assunto; `in_review` só
  com caminho de revisão real (interação, approval, usuário do board, participante ou monitor),
  senão `done` ou `blocked` com `unblockDescriptor`.

## Segredos

Nenhum segredo está no repositório. A chave do board é lida em tempo de execução de
`/etc/paperclip-telegram.env` (`PAPERCLIP_BOARD_API_KEY`, root 0600); credenciais
IMAP vêm de `/etc/paperclip-mail.env`.

## Placeholders

Endereços de e-mail reais foram trocados antes do commit. Ao reinstalar, substitua:

- `operador@example.invalid` → usuário IMAP do Proton Bridge
- `operador-cliente@example.invalid` → endereço do operador no cliente
- `caixa-projetos@example.invalid` / `caixa-projetos` → caixa de projetos monitorada

## Instalar

```sh
cp -a usr etc var /            # como root na LXC 108, após trocar os placeholders
chmod 700 /usr/local/bin/paperclip-{manager,verify,watchdog,deliver,autofallback,healthcheck,notify} \
          /usr/local/bin/{guardian-watch,revert-fallback}
crontab crontab-root.txt
systemctl daemon-reload
```
