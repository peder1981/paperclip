# Fix: issue orphanada em reatribuição/terminalização durante run vivo

## Sintoma observado (JMPM, 04–05/11/2026)
Agente executando chama PATCH reatribuindo a própria issue (ex.: Secretina → CTO
na JMP-189). O run era cancelado com `issue_reassigned`, mas a **reatribuição
não commitava**: issue ficava com o assignee antigo, sem run vivo, sem wakeup —
órfã, exigindo intervenção manual do operador (2x no mesmo dia).

## Causa raiz
`server/src/routes/issues.ts` — nos caminhos `issue_reassigned` e
`issue_terminalized`, o código cancela o run **antes** de aplicar o update e
exigia `cancelled.status === "cancelled"`. Porém `cancelRunInternal`
(`server/src/services/heartbeat/run-control.ts`) **retorna o run inalterado**
quando o status não está em `CANCELLABLE_HEARTBEAT_RUN_STATUSES` — ou seja,
run já terminal (morrendo por outra via) → retorna status terminal → a rota
faz `throw conflict("runner_goal_reassignment_stop_unconfirmed")` → o update
da issue aborta, mas o run já estava morto → issue órfã.

## Correção
Em ambos os caminhos, um run em estado terminal (`succeeded`, `interrupted`,
`failed`, `timed_out`) passa a contar como "parado" — não há mais nada a
parar. O `throw conflict` só dispara quando o run segue vivo e o cancelamento
realmente falhou. Alteração mínima, sem mudança de contrato.

## Complementos operacionais (fora do fonte, já aplicados no ambiente)
- Emenda "PASSAGEM DE BASTÃO OBRIGATÓRIA" nos AGENTS.md dos 12 agentes:
  proibido encerrar "esperando" outro agente sem mencioná-lo com @<uuid>
  (a menção é o mecanismo de wake).
- Sentinela Júnior instruído a detectar issue órfã (assignee sem run
  `running`/`queued`) e acordar o responsável — cobre qualquer resíduo desse
  padrão até o fix subir em produção.
- Rotina de digest e instruções limpas de referências ao agente
  "Gerente de Projetos" (terminated) — escaladas vão direto ao CTO.

## Continuação — wakeups de comentário (deferred_issue_execution)

Mecanismo: comentário durante run viva vira wake `deferred_issue_execution`
(entregue à fila da execução). `resumeQueuedRuns()` em
`server/src/services/heartbeat/queue.ts` (~1755-1830) promove wakes stranded,
mas SÓ quando `issues.executionRunId IS NULL` — se a issue retém
executionRunId de um run já terminal, o wake deferred pode ficar preso e o
comentário nunca chega ao agente (agente "ignora" a ordem).

Verificar: `releaseIssueExecutionAndPromote` na finalização do run legacy —
confirma se executionRunId é anulado e se a promoção do wake deferred ocorre
em TODO run que termina (não só recovery). Se a issue JMP-194 ficou com
executionRunId stale após `succeeded`, o guard stranded nunca a viu.

Workaround operacional (validado): `POST /api/agents/{id}/wakeup`
{"reason":"...","triggerDetail":"system"} — gera run novo que lê os
comentários pendentes no contexto. NUNCA inserir wakeup/comentário via SQL:
a aplicação mantém formato e dispara os ganchos certos.

Também observado: `issue_state_guard_mismatch` barra wakes quando
statusVersion muda entre queue e claim — avaliar se comentários ao MESMO
assignee deveriam tolerar bump de statusVersion.
