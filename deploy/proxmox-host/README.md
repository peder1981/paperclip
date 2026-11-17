# Operação do host Proxmox (homelab)

Cópia dos scripts, crons, units systemd e regras de logrotate do host Proxmox.
A árvore espelha os caminhos absolutos (`usr/local/sbin/…` → `/usr/local/sbin/…`).
Entry points gerados por pacotes pip foram omitidos.

## Rotinas principais

| Script | Função | Agenda |
|---|---|---|
| `usr/local/sbin/homelab-maint.sh maintain` | limpeza diária do host e de cada LXC: journald, apt, tmp, logs antigos, core dumps (fora do storage do Docker), logs e imagens Docker sem uso | 04:50 (`etc/cron.d/homelab-maint`) |
| `usr/local/sbin/homelab-maint.sh check` | disco, montagens, units com falha, SMART, erros de FS, idade dos backups; alerta via `telegram-notify` com intervalo de 12h | hora em hora, :20 |
| `usr/local/sbin/ct-thin-trim.sh` | libera espaço do thin pool `pve/data` | 04:15 |
| `usr/local/bin/pve-daily-hygiene.sh` | higiene diária do host | 04:30 (`crontab-root.txt`) |
| `usr/local/bin/pve-fstrim-all` | fstrim de todas as LXCs | domingo 03:30 |
| `usr/local/sbin/homelab-maintenance-window.sh` | janela de manutenção | 03:30 a cada 5 dias |
| `usr/local/bin/monitor-proxmox.sh` | monitor com relatórios no Telegram e intervalo de 6h entre alertas repetidos | `*/5`, `*/30`, 08:00 |
| `usr/local/bin/monitor-pool.sh`, `monitor-blu.sh`, `monitor-gescon.sh`, `monitor-justatistic-ledger.sh` | monitores específicos | ver `crontab-root.txt` |
| `etc/logrotate.d/homelab-custom` | rotação dos logs personalizados | diária |

A verificação semanal do PBS (`verify-local-ct`, sábado 05:30) fica na configuração do
PBS (LXC 100), não neste diretório.

## Segredos

Nenhum segredo está no repositório. Os scripts leem credenciais de arquivos locais
(`/etc/telegram-notify.conf`, `/etc/proton-mail.conf`, `/etc/minio.env`,
`EnvironmentFile=` das units).

## Placeholders

Dados pessoais foram trocados antes do commit. Ao reinstalar, substitua:

- `operador@example.invalid` → remetente Proton
- `operador-proton@example.invalid` → destinatário dos avisos
- `laptop-operador` / `operador@laptop-operador…` → hostname e usuário do laptop

## Instalar

```sh
cp -a usr etc /                 # como root no host, após trocar os placeholders
crontab crontab-root.txt
systemctl daemon-reload
```
