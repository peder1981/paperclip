# ORTA023D.PRW — Documento de Alterações

**Projeto:** Boavista — Integração de arquivos de cartão
**Issues:** JMP-57 (parser Vero/BJR), JMP-84 (layout Banrisul), JMP-85 (logs u_JobCInfo), JMP-56 (Credishop 3.4/3.4.1), EEVD/RD
**Fonte canônico:** `entregas/ORTA023D.prw` — md5 `3f17f06a8c248bc41736ca15c7f5bd03`
**Espelhos:** `my-advpl-project/Ortobom/Utilitarios/ORTBJOB/orta023d.prw`, `LXC108 tecnico/JMP-57/candidato-unido/ORTA023D.PRW`
**Compilação:** COMPILE_RC=0
**Formato:** cp1252 + CRLF (destino Windows)

---

## 1. Roteamento Vero / Banrisul (JMP-57 / JMP-84)

**Problema:** amostras reais BJR02/BJR06/BJR76 trazem `BANRISUL` na posição 073 mas IDs `BJRVCA1`/`BJRVCC1`/`BJRVCMB` na posição 043 — roteavam errado.

**Correção em `LocFun()`:**
- Banrisul **exclui** IDs `BJRVC*` 
- Novo ramo Vero: `pos73 == "VERO" .OR. pos43 == "BJRVC"` → `Vero()`

## 2. Credishop 3.4 / 3.4.1 (JMP-56)

- Detecção por `CredLay341()` (campo a campo contra o manual "Layout Credishop v3.4.1")
- Mapeamento diferenciado por layout; data de crédito (pos. 42–49) em `dDataVen`
- Aceita tipos `PRE` e `PAG` (resumos faixas 1xxxxxxx e 2xxxxxxx)
- Rodapé tipo 9 validado contra total de linhas lidas

## 3. Banese — registros 3 e 4

- **Registro 3:** não soma; `nVlParc` herda do registro 2 anterior (direção do operador)
- **Registro 4:** ajustes processados (antes ignorados)

## 4. EEVD — arquivos RD (Novo)

**Problema:** arquivos `*_RD_*.TXT` (Redecard EEVD, CSV) não eram processados — o header CSV casava com `REDECARD` na pos.72 e caía no `RedeShop()` (parser CSV de outro layout).

**Correção:**
- Ramo EEVD movido para **primeiro** da cadeia `LocFun`: `Substr(cBuffer,1,3)=="00," .And. (",Redecard," $ cBuffer .Or. "EEVD" $ upper(cBuffer))` → `EEVD()`
- **Nova `Static Function EEVD()`**: parser CSV via `Arruma()` existente; registros `00` (header), `011` (movimento débito), demais tipos → log + skip
- Valores monetários: `/100` (últimos 2 dígitos = decimais — regra confirmada pelo operador)
- Campos do registro `011`: estab, resumo, data, valor, D/C, descrição, cartão, dt venda, autorização

## 5. Cópia de arquivos — `JMPcp()` (evolução)

| Tentativa | Resultado |
|---|---|
| `COPY FILE &x TO &y` (legado) | removido |
| `MsCopyTo()` | **errado** — copia tabela RDD, gerou `ORA-00903` (`CREATE TABLE <arquivo>`) |
| `MemoRead`/`MemoWrit` | descartado |
| `__CopyFile()` | compilava mas falhava em runtime |
| **`SMCopy()`** ✅ | validado em produção |

`JMPcp(cOri, cDst)` garante `MakeDir` do diretório destino antes de `SMCopy` + `U_JobCInfo` na falha — resolve o `falha ao copiar ...\lido\` de produção.

## 6. Limite de tamanho

Arquivos > **5MB** são ignorados com log (`u_JobCInfo`, nível 1) antes de qualquer processamento.

## 7. Instrumentação u_JobCInfo (JMP-85)

**33+ chamadas** cobrindo: início/fim, lock de instância, contagem de arquivos, entrada no LocFun, ramo de cada operadora, falhas de abertura, arquivo inválido, limite de erros, header/movimento/resumo EEVD, falha de cópia, JOB (PREPARANDO/INICIO/FIM). Níveis: `1`=erro, `2`=info.

## 8. Validação

| Evidência | Resultado |
|---|---|
| Compilação | COMPILE_RC=0 (todas as iterações) |
| Execução real | 144 arquivos roteados — "Processando Vero" OK |
| Roteamento simulado | 18 Credishop + 9 RC/RD/RF + 30 Banrisul — 100% corretos |
| Bug encontrado e corrigido | RD roteava p/ RedeShop (pos.72) → EEVD agora é 1º da cadeia |
