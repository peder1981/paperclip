#!/usr/bin/env python3
"""Ponte Paperclip <-> Telegram (v8).

Leitura: banco do Paperclip (SELECT). Escrita: API local do Paperclip com a
chave de board do operador (PAPERCLIP_BOARD_API_KEY). Toda ação de escrita
exige toque de confirmação no Telegram. Só o TELEGRAM_ALLOWED_USER_ID age.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TG_ENV = "/etc/paperclip-telegram.env"
PC_ENV = "/etc/paperclip.env"
STATE = "/var/lib/paperclip/tools/telegram-bridge/state.json"
API = "http://127.0.0.1:3100/api"
COMPANY = "c9a85ff4-4643-4105-a6e5-0c6e54e3aea8"
POLL_SECONDS = 60
SEP = "\x1f"
PENDING_STATUS = {"in_review", "blocked"}
CLOSED_STATUS = {"done", "cancelled"}


def read_env(path):
    values = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


TG = read_env(TG_ENV)
TOKEN = TG["TELEGRAM_BOT_TOKEN"]
ALLOWED = int(TG["TELEGRAM_ALLOWED_USER_ID"])
BOARD_KEY = TG.get("PAPERCLIP_BOARD_API_KEY", "")
DATABASE_URL = read_env(PC_ENV)["DATABASE_URL"]


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def query(sql):
    out = subprocess.run(
        ["psql", DATABASE_URL, "-X", "-A", "-t", "-F", SEP, "-c", sql],
        capture_output=True, text=True, timeout=60,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return [line.split(SEP) for line in out.stdout.splitlines() if line]


def sql_lit(value):
    return "'" + str(value).replace("'", "''") + "'"


def tg_call(method, params=None):
    data = urllib.parse.urlencode(params or {}, doseq=False).encode()
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    try:
        with urllib.request.urlopen(url, data=data, timeout=40) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as exc:
        log(f"tg_call {method} HTTP {exc.code}: {exc.read(200).decode(errors='replace')}")
        raise
    except Exception:
        log(f"tg_call {method} falhou (nao-HTTP)")
        raise
    if not body.get("ok"):
        raise RuntimeError(f"telegram {method}: {body.get('description')}")
    return body["result"]


def send(text, buttons=None):
    params = {"chat_id": ALLOWED, "text": text[:3900], "disable_web_page_preview": "true"}
    if buttons:
        params["reply_markup"] = json.dumps({"inline_keyboard": buttons})
    return tg_call("sendMessage", params)


def api(method, path, body=None):
    if not BOARD_KEY:
        raise RuntimeError("chave de board não configurada (PAPERCLIP_BOARD_API_KEY)")
    data = json.dumps(body or {}).encode()
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {BOARD_KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"API {exc.code} em {path}: {exc.read(300).decode(errors='replace')}")


def load_state():
    if os.path.exists(STATE):
        with open(STATE, encoding="utf-8") as fh:
            state = json.load(fh)
    else:
        state = {}
    state.setdefault("issues", {})
    state.setdefault("last_comment_at", None)
    state.setdefault("tg_offset", 0)
    state.setdefault("primed", False)
    state.setdefault("asked", {})        # interaction id -> True quando enviada
    state.setdefault("approvals", {})    # approval id -> True quando enviada
    state.setdefault("drafts", {})       # interaction id -> {question id: [option ids], texts}
    state.setdefault("await_text", None)  # {"iid":..., "qid":..., "opt":...}
    state.setdefault("confirm", {})      # token -> ação pendente de confirmação
    return state


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False)
    os.replace(tmp, STATE)


# ---------- leitura do banco ----------

def snapshot_issues():
    rows = query(
        "select i.id, i.identifier, replace(i.title, chr(10), ' '), i.status, "
        "coalesce(p.name, '(avulso)'), coalesce(i.origin_kind, '') "
        "from issues i left join projects p on p.id = i.project_id "
        "where i.identifier like 'JMP-%' order by i.identifier")
    return {r[0]: {"identifier": r[1], "title": r[2], "status": r[3], "project": r[4], "origin": r[5]} for r in rows}


def new_comments(since):
    where = f"and c.created_at > {sql_lit(since)}" if since else ""
    return query(
        "select c.created_at, i.identifier, coalesce(a.name, c.author_type, 'autor') "
        "from issue_comments c join issues i on i.id = c.issue_id "
        "left join agents a on a.id = c.author_agent_id "
        f"where i.identifier like 'JMP-%' {where} order by c.created_at limit 50")


def pending_interactions():
    rows = query(
        "select t.id, i.id, i.identifier, replace(i.title, chr(10), ' '), t.payload::text "
        "from issue_thread_interactions t join issues i on i.id = t.issue_id "
        "where t.status = 'pending' and t.kind = 'ask_user_questions' order by t.created_at")
    out = []
    for iid, issue_id, ident, title, payload in rows:
        out.append({"id": iid, "issue_id": issue_id, "identifier": ident,
                    "title": title, "payload": json.loads(payload)})
    return out



DELEGATION_PAT = (
    # Delegação
    "quem deve atribuir", "quem atribui", "confirme que o gerente",
    "confirme a atribui", "deve fazer a atribu", "atribuicao do subtask",
    "confirme que", "quem executa", "quem deve executar",
    # Confirmações de leitura
    "confirme que leu", "confirme que entendeu", "confirme recebimento",
    "favor confirmar", "confirme que viu",
    # Status triviais
    "confirme o status", "qual o status atual", "atualize o status",
    # Validações intermediárias
    "validar que o plano", "validar a abordagem", "confirme a abordagem",
    "posso prosseguir", "posso seguir", "devo prosseguir",
    "autoriza prosseguir", "permissao para continuar",
    # Formato de entrega
    "qual formato", "como prefere receber", "em que formato",
    # Nomes de campo quando ficha existe
    "qual nome para o campo", "confirme o nome do campo",
)

def is_trivial_escalation(item):
    prompts = " ".join(q.get("prompt", "").lower() for q in item["payload"].get("questions", []))
    if not prompts:
        return False
    return any(pat in prompts for pat in DELEGATION_PAT)


def auto_answer(item):
    """Responde escalacao trivial sem incomodar o operador."""
    answers = []
    for q in item["payload"].get("questions", []):
        a = {"questionId": q["id"], "optionIds": [],
             "otherText": ("Resposta automatica (governance v2): decidir internamente. "
                           "Hierarquia: agente proprio -> consulta entre pares -> CTO (tecnico) -> Gerente (operacional). "
                           "Operador so para: cliente externo, gasto, negocio sem evidencia, acao irreversivel fora sandbox. Prossiga.")}
        if q.get("options"):
            a["optionIds"].append(q["options"][0]["id"])
        answers.append(a)
    api("POST", f"/issues/{item['issue_id']}/interactions/{item['id']}/respond",
        {"answers": answers, "summaryMarkdown": "Auto-resposta (governance v2): questao resolvida pela hierarquia interna — decidir e executar."})
    send(f"🛡 {item['identifier']}: pergunta de delegacao auto-respondida (nao escalar).")



MAIL_TO = ["operador-cliente@example.invalid", "operador@example.invalid"]
OUTBOX = "/var/lib/paperclip/outbox/"
SENDMAIL = "/usr/local/bin/paperclip-send-mail"
SENT_LEDGER = "/var/lib/paperclip-mail/sent.log"  # gravado por paperclip-send-mail


def already_delivered(ident):
    """Data do envio de entrega ja feito para o issue, ou None.
    ponytail: entrega = envio com anexo a um endereco do operador; mensagem sem anexo nao conta."""
    try:
        for line in open(SENT_LEDGER, encoding="utf-8"):
            p = line.rstrip("\n").split("\t")
            if len(p) == 4 and p[1] == ident and p[2] in MAIL_TO and p[3] != "0":
                return p[0]
    except FileNotFoundError:
        pass
    return None


def find_best_deliverable(iid):
    """Seleciona o melhor comentario de entrega: prefere comentarios com paths
    /var/lib/paperclip/ e evidencia real (fontes, diffs, changelogs)."""
    rows = query(
        "select c.id, left(replace(replace(c.body, chr(10), ' '), chr(13), ''), 12000), c.created_at from issue_comments c "
        "where c.issue_id = " + sql_lit(iid) +
        " order by c.created_at desc limit 20")
    if not rows:
        return None, "(sem comentario final)"
    best = None
    best_score = -1
    for cid, body, ts in rows:
        score = 0
        if "/var/lib/paperclip/" in body:
            score += 10
        if re.search(r"\.(prw|tlpp|prg|py|md|txt|diff|patch)", body, re.I):
            score += 5
        for kw in ("changelog", "diff", "evidencia", "compilad", "entrega", "anexo"):
            if kw in body.lower():
                score += 2
        # penaliza meta-comentarios curtos
        if len(body) < 200:
            score -= 3
        if score > best_score:
            best_score = score
            best = (cid, body, ts)
    if best is None:
        best = (rows[0][0], rows[0][1], rows[0][2])
    return best[0], best[1]


def materialize_deliverable(iid, ident, body):
    """Se o comentario de entrega nao referencia arquivos fisicos, materializa
    o conteudo como .md em /var/lib/paperclip/tecnico/."""
    tecnico = "/var/lib/paperclip/tecnico"
    os.makedirs(tecnico, exist_ok=True)
    if "/var/lib/paperclip/" in body:
        # ja tem referencia a arquivos fisicos
        return []
    fname = f"{tecnico}/entrega-{ident}.md"
    with open(fname, "w", encoding="utf-8") as fh:
        fh.write(f"# Entrega {ident}\n\n{body}")
    return [fname]


def collect_attachments(body):
    """Extrai paths de arquivos mencionados no corpo do comentario."""
    paths = re.findall(r"(/var/lib/paperclip/[^\s)\]]+)", body)
    return [p for p in paths if os.path.isfile(p)]


def send_deliverable_mail(iid, ident, title):
    """Envia o entregavel do issue concluido para os dois e-mails do operador.
    v8: selecao inteligente de entregavel, materializacao, anexos fisicos."""
    _, body = find_best_deliverable(iid)
    materialized = materialize_deliverable(iid, ident, body)
    attachments = collect_attachments(body) + materialized
    header = (f"Entrega: {ident}\nTitulo: {title}\nStatus: done\n"
              f"Board: https://paperclip.example.invalid/JMP/issues/{ident}\n"
              f"{'='*60}\n\nEntregavel selecionado pelo agente:\n\n")
    fname = f"{OUTBOX}entrega-{ident}.txt"
    with open(fname, "w", encoding="utf-8") as fh:
        fh.write(header + body)
    subject = f"[Entrega Paperclip] {ident} - {title[:80]}"
    for dest in MAIL_TO:
        cmd = [SENDMAIL, dest, subject, fname]
        for att in attachments:
            cmd.extend(["--attach", att])
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            log(f"erro envio email {dest}: {result.stderr[:200]}")


def pending_approvals():
    rows = query(
        "select id, type, coalesce(payload::text, '{}') from approvals "
        "where status = 'pending' and company_id = " + sql_lit(COMPANY) + " order by created_at")
    return [{"id": r[0], "type": r[1], "payload": r[2][:300]} for r in rows]



def issue_lookup(ident):
    ident = ident.upper().strip()
    if not ident.startswith("JMP-"):
        ident = "JMP-" + ident.lstrip("JMP-")
    rows = query(
        "select i.id, i.identifier, replace(i.title, chr(10), ' '), i.status, "
        "coalesce(a.name, '-') from issues i "
        "left join agents a on a.id = i.assignee_agent_id "
        "where i.identifier = " + sql_lit(ident) + " limit 1")
    return rows[0] if rows else None


def issue_detail(ident):
    row = issue_lookup(ident)
    if not row:
        return "Issue não encontrada: " + ident
    iid, ident, title, status, owner = row
    last = query(
        "select left(replace(c.body, chr(10), ' '), 600), c.created_at "
        "from issue_comments c where c.issue_id = " + sql_lit(iid) +
        " order by c.created_at desc limit 1")
    txt = f"{ident} [{status}] {owner}\n{title[:150]}"
    if last:
        txt += f"\n\nÚltimo comentário ({last[0][1][:16]}):\n{last[0][0]}"
    return txt


def agents_text():
    rows = query(
        "select name, adapter_type, status from agents "
        "where status <> 'terminated' order by status, name")
    return "Agentes:\n" + "\n".join(f"- {n} [{ad}] {st}" for n, ad, st in rows)


def runs_text():
    rows = query(
        "select r.status, coalesce(i.identifier, '-'), a.name, "
        "coalesce(left(r.error, 120), ''), r.created_at::text "
        "from heartbeat_runs r left join issues i on i.id = r.issue_id "
        "join agents a on a.id = r.agent_id order by r.created_at desc limit 8")
    lines = ["Últimas runs:"]
    for st, ident, ag, err, ts in rows:
        mark = "❌" if st == "failed" else ("✅" if st == "succeeded" else "⏳")
        line = f"{mark} {ts[:16]} {ident} {ag}: {st}"
        if err:
            line += f" — {err[:80]}"
        lines.append(line)
    return "\n".join(lines)


def agent_id_by_name(fragment):
    frag = fragment.strip().lower()
    rows = query(
        "select id, name from agents where status <> 'terminated' order by name")
    exact = [r for r in rows if r[1].lower() == frag]
    if exact:
        return exact[0]
    part = [r for r in rows if frag in r[1].lower()]
    if len(part) == 1:
        return part[0]
    return None


def status_text():
    rows = query(
        "select identifier, replace(title, chr(10), ' '), status from issues "
        "where identifier like 'JMP-%' and status not in ('done','cancelled') order by identifier")
    if not rows:
        return "Nenhum issue aberto."
    lines = ["Issues abertos:"]
    for ident, title, status in rows:
        flag = " ⏸ aguarda decisão" if status in PENDING_STATUS else ""
        lines.append(f"- {ident} [{status}]{flag}: {title[:90]}")
    return "\n".join(lines)


def project_digest():
    rows = query(
        "select coalesce(p.name, 'Sem projeto'), i.identifier, replace(i.title, chr(10), ' '), "
        "i.status, coalesce(a.name, '-') "
        "from issues i left join projects p on p.id = i.project_id "
        "left join agents a on a.id = i.assignee_agent_id "
        "where i.company_id = " + sql_lit(COMPANY) + " and i.status not in ('cancelled') "
        "order by 1, i.identifier")
    projects = {}
    for pname, ident, title, status, owner in rows:
        proj = projects.setdefault(pname, {"open": [], "done": 0})
        if status == "done":
            proj["done"] += 1
        else:
            proj["open"].append((ident, title, status, owner))
    if not projects:
        return "Nenhum projeto com issues."
    blocks = []
    for pname, proj in sorted(projects.items()):
        open_items = proj["open"]
        active = [o for o in open_items if o[2] == "in_progress" or o[2] == "in_review"]
        waiting = [o for o in open_items if o[2] == "blocked"]
        if not open_items:
            etapa = "concluído"
        elif waiting and not active:
            etapa = "PARADO — aguarda sua decisão"
        elif active:
            etapa = "em andamento"
        else:
            etapa = "não iniciado"
        lines = [f"▶ {pname}", f"Etapa: {etapa}. Concluídos: {proj['done']}."]
        for ident, title, status, owner in open_items:
            mark = "⏸" if status == "blocked" else ("🔎" if status == "in_review" else "🔧")
            lines.append(f"{mark} {ident} [{status}] {owner}: {title[:70]}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


# ---------- perguntas (interações) ----------

def send_interaction(item, state):
    p = item["payload"]
    send(f"❓ {item['identifier']} — {item['title'][:100]}\n"
         f"Pergunta(s) aguardando sua resposta. Escolha abaixo.")
    for qi, q in enumerate(p.get("questions", [])):
        buttons = []
        for oi, opt in enumerate(q.get("options", [])):
            if opt.get("freeText"):
                buttons.append([{"text": "✏️ " + opt.get("label", "Texto")[:40],
                                 "callback_data": f"t|{item['id']}|{qi}|{oi}"}])
            else:
                buttons.append([{"text": opt.get("label", "")[:60],
                                 "callback_data": f"q|{item['id']}|{qi}|{oi}"}])
        send(f"{q.get('prompt', '')}", buttons or None)
    state["asked"][item["id"]] = True


def ready_to_submit(item_id, state):
    item = state["items"].get(item_id)
    if not item:
        return False
    drafts = state["drafts"].get(item_id, {})
    for q in item["payload"].get("questions", []):
        if q.get("required", True) and q["id"] not in drafts:
            return False
    return True


def answers_for(item_id, state):
    item = state["items"][item_id]
    drafts = state["drafts"].get(item_id, {})
    answers = []
    for q in item["payload"].get("questions", []):
        if q["id"] not in drafts:
            continue
        d = drafts[q["id"]]
        answers.append({"questionId": q["id"], "optionIds": d["options"],
                        "otherText": d.get("text")})
    return answers


def handle_callback(cb, state):
    sender = (cb.get("from") or {}).get("id")
    if sender != ALLOWED:
        return
    data = cb.get("data", "")
    parts = data.split("|")
    tg_call("answerCallbackQuery", {"callback_query_id": cb["id"]})
    kind = parts[0]
    if kind in ("q", "t"):
        iid, qi, oi = parts[1], int(parts[2]), int(parts[3])
        item = state["items"].get(iid)
        if not item:
            send("Pergunta não encontrada. Use /pendencias.")
            return
        q = item["payload"]["questions"][qi]
        opt = q["options"][oi]
        if kind == "t":
            state["await_text"] = {"iid": iid, "qid": q["id"], "opt": opt["id"]}
            send(f"Escreva a resposta para: {q['prompt'][:200]}")
            return
        drafts = state["drafts"].setdefault(iid, {})
        if q.get("selectionMode") == "multiple":
            cur = drafts.get(q["id"], {"options": [], "text": None})
            if opt["id"] in cur["options"]:
                cur["options"].remove(opt["id"])
            else:
                cur["options"].append(opt["id"])
            drafts[q["id"]] = cur
        else:
            drafts[q["id"]] = {"options": [opt["id"]], "text": None}
        if ready_to_submit(iid, state):
            token = f"s{len(state['confirm'])}{int(time.time())}"
            state["confirm"][token] = {"kind": "answer", "iid": iid}
            send(f"Enviar as respostas para {item['identifier']}?",
                 [[{"text": "✅ Confirmar envio", "callback_data": f"c|{token}"},
                   {"text": "✖ Cancelar", "callback_data": f"x|{token}"}]])
        else:
            send(f"Registrado: {opt.get('label', '')}. Faltam perguntas.")
        return
    if kind == "a":
        aid, action = parts[1], parts[2]
        token = f"a{int(time.time() * 1000) % 10**9}"
        state["confirm"][token] = {"kind": "approval", "id": aid, "action": action}
        label = "aprovar" if action == "approve" else "rejeitar"
        send(f"Confirma {label} a aprovação {aid[:8]}?",
             [[{"text": "✅ Confirmar", "callback_data": f"c|{token}"},
               {"text": "✖ Cancelar", "callback_data": f"x|{token}"}]])
        return
    if kind == "c":
        act = state["confirm"].pop(parts[1], None)
        if not act:
            send("Ação expirada. Use /pendencias.")
            return
        try:
            execute_confirmed(act, state)
        except Exception as exc:
            send(f"Não consegui concluir a ação: {exc}")
            log(f"falha na ação confirmada: {exc}")
        return
    if kind == "x":
        state["confirm"].pop(parts[1], None)
        send("Cancelado.")


def execute_confirmed(act, state):
    if True:
        if act["kind"] == "answer":
            item = state["items"][act["iid"]]
            api("POST", f"/issues/{item['issue_id']}/interactions/{act['iid']}/respond",
                {"answers": answers_for(act["iid"], state),
                 "summaryMarkdown": "Respondido pelo operador via Telegram."})
            state["drafts"].pop(act["iid"], None)
            send(f"Respostas enviadas para {item['identifier']}.")
            log(f"respondida interação {act['iid']} ({item['identifier']})")
        elif act["kind"] == "comment":
            api("POST", f"/issues/{act['iid']}/comments", {"body": act["body"]})
            send(f"Comentário postado em {act['ident']}.")
            log(f"comentario em {act['ident']} ({act['iid']})")
        elif act["kind"] == "status":
            api("PATCH", f"/issues/{act['iid']}", {"status": act["status"]})
            send(f"{act['ident']} → {act['status']}.")
            log(f"status {act['ident']} -> {act['status']}")
        elif act["kind"] == "assign":
            api("PATCH", f"/issues/{act['iid']}",
                {"assigneeAgentId": act["agent"]})
            send(f"{act['ident']} atribuída a {act['agent_name']}.")
            log(f"assign {act['ident']} -> {act['agent_name']}")
        else:
            verb = "approve" if act["action"] == "approve" else "reject"
            api("POST", f"/approvals/{act['id']}/{verb}",
                {"decisionNote": "Decidido pelo operador via Telegram."})
            send(f"Aprovação {act['id'][:8]} — {verb} enviado.")
            log(f"aprovação {act['id']} {verb}")



def ask_confirm(state, act, prompt):
    token = f"k{int(time.time() * 1000) % 10**9}"
    state["confirm"][token] = act
    send(prompt, [[{"text": "✅ Confirmar", "callback_data": f"c|{token}"},
                   {"text": "✖ Cancelar", "callback_data": f"x|{token}"}]])


HELP_TEXT = """Comandos disponíveis — MeuGerente_bot

Leitura (não alteram nada):
/status — lista todos os issues abertos com status; marca quem aguarda sua decisão.
/projetos — resumo por projeto: etapa, concluídos e itens abertos com responsável.
/pendencias — envia as perguntas abertas dos agentes e as aprovações pendentes, com botões para responder.
/agentes — lista os agentes ativos: nome, tipo de adapter (claude/opencode) e estado atual.
/runs — últimas 8 execuções de agentes: sucesso, falha ou em andamento, com o erro quando houver.
/issue JMP-NN — detalhe de um issue: status, responsável e o último comentário.

Escrita (sempre pedem confirmação por botão antes de executar):
/comentar JMP-NN <texto> — posta um comentário seu no issue; os agentes leem e reagem.
  Ex.: /comentar JMP-36 Recebi o SFTP, pasta é /cartoes/entrada
/mover JMP-NN <status> — muda o status do issue.
  Status aceitos: backlog, todo, in_progress, in_review, blocked, done, cancelled.
  Útil para destravar issues (blocked → todo) ou encerrar (→ done).
  Ex.: /mover JMP-20 todo
/atribuir JMP-NN <agente> — passa o issue para outro agente; aceita nome parcial.
  Agentes hoje: Agnes, Analista Funcional Protheus, Secretina (opencode);
  CTO, Gerente de Projetos, Desenvolvedor Protheus Sênior, Especialista em Integrações (claude).
  Ex.: /atribuir JMP-37 agnes

Aprovações e perguntas: quando um agente pergunta ou pede aprovação, o bot envia
botões automaticamente — toque na opção e confirme o envio.

Outros: /ajuda ou /help mostra esta mensagem. /start idem.
Só o seu usuário autorizado executa comandos; escritas exigem confirmação."""


def handle_text(msg, state):
    text = (msg.get("text") or "").strip()
    if text.startswith("/status"):
        send(status_text())
    elif text.startswith("/projetos"):
        send(project_digest())
    elif text.startswith("/agentes"):
        send(agents_text())
    elif text.startswith("/runs"):
        send(runs_text())
    elif text.startswith("/issue"):
        parts = text.split(None, 1)
        send(issue_detail(parts[1] if len(parts) > 1 else ""))
    elif text.startswith("/comentar"):
        parts = text.split(None, 2)
        row = issue_lookup(parts[1]) if len(parts) > 1 else None
        if not row or len(parts) < 3:
            send("Uso: /comentar JMP-NN texto do comentário")
        else:
            ask_confirm(state,
                {"kind": "comment", "iid": row[0], "ident": row[1], "body": parts[2]},
                f"Postar comentário em {row[1]}?\n\n{parts[2][:400]}")
    elif text.startswith("/mover"):
        parts = text.split(None, 2)
        row = issue_lookup(parts[1]) if len(parts) > 1 else None
        allowed = {"backlog","todo","in_progress","in_review","blocked","done","cancelled"}
        novo = parts[2].strip().lower() if len(parts) > 2 else ""
        if not row or novo not in allowed:
            send("Uso: /mover JMP-NN status — " + "|".join(sorted(allowed)))
        else:
            ask_confirm(state,
                {"kind": "status", "iid": row[0], "ident": row[1], "status": novo},
                f"Mover {row[1]} de {row[3]} → {novo}?")
    elif text.startswith("/atribuir"):
        parts = text.split(None, 2)
        row = issue_lookup(parts[1]) if len(parts) > 1 else None
        ag = agent_id_by_name(parts[2]) if len(parts) > 2 else None
        if not row or not ag:
            send("Uso: /atribuir JMP-NN nome-do-agente (ex.: /atribuir JMP-37 agnes)")
        else:
            ask_confirm(state,
                {"kind": "assign", "iid": row[0], "ident": row[1],
                 "agent": ag[0], "agent_name": ag[1]},
                f"Atribuir {row[1]} para {ag[1]}?")
    elif text.startswith("/pendencias"):
        for item in pending_interactions():
            state["items"][item["id"]] = item
            send_interaction(item, state)
        for ap in pending_approvals():
            buttons = [[{"text": "✅ Aprovar", "callback_data": f"a|{ap['id']}|approve"},
                        {"text": "✖ Rejeitar", "callback_data": f"a|{ap['id']}|reject"}]]
            send(f"Aprovação pendente ({ap['type']}): {ap['id'][:8]}", buttons)
        send("Fim da lista de pendências.")
    elif text.startswith(("/ajuda", "/help", "/start")):
        send(HELP_TEXT)
    elif state.get("await_text"):
        aw = state["await_text"]
        state["await_text"] = None
        drafts = state["drafts"].setdefault(aw["iid"], {})
        drafts[aw["qid"]] = {"options": [aw["opt"]], "text": text[:100000]}
        if ready_to_submit(aw["iid"], state):
            token = f"s{int(time.time() * 1000) % 10**9}"
            state["confirm"][token] = {"kind": "answer", "iid": aw["iid"]}
            send("Enviar as respostas?", [[{"text": "✅ Confirmar envio", "callback_data": f"c|{token}"},
                                           {"text": "✖ Cancelar", "callback_data": f"x|{token}"}]])
        else:
            send("Texto registrado. Faltam perguntas.")



# Fallbacks por agente: modelo primario -> lista de fallback em ordem.
MODEL_FALLBACKS = {
    # OpenCode agents: Agnes → LFM3 (moderno, 1.7B) → Granite (legado, 8B)
    "Secretina": ["paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b", "ollama/granite4.1:8b"],
    "Agnes": ["paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b", "ollama/granite4.1:8b"],
    "Analista Funcional Protheus": ["agnes-2.5-flash", "ollama/lfm3:1.7b", "ollama/granite4.1:8b"],
    # Claude agents: Claude → Agnes → LFM3 (moderno, leve, rapido)
    "Chief Tecnology Officer": ["claude-haiku-5-5", "paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b"],
    "Gerente de Projetos": ["claude-haiku-5-5", "paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b"],
    "Especialista em Integrações TOTVS": ["claude-haiku-5-5", "paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b"],
    "Desenvolvedor Protheus Sênior": ["claude-sonnet-5-5", "paperclip/agnes-2.5-flash", "ollama/lfm3:1.7b"],
}
GROUP_ERR = "not available for your current group"

# Failover cross-adapter: agente opencode morto -> agente Claude (familia independente)
FAILOVER_MAP = {
    # OpenCode → Claude (quando toda a cadeia OpenCode esgota)
    "Secretina": "Gerente de Projetos",
    "Agnes": "Desenvolvedor Protheus Sênior",
    "Analista Funcional Protheus": "Chief Tecnology Officer",
    # Claude → OpenCode (quando toda a cadeia Claude esgota)
    "Chief Tecnology Officer": "Secretina",
    "Gerente de Projetos": "Secretina",
    "Especialista em Integrações TOTVS": "Agnes",
    "Desenvolvedor Protheus Sênior": "Agnes",
}


def model_watchdog(state):
    """Se o ultimo run de um agente falhou por erro de grupo, troca o modelo
    para o proximo fallback. Reverte ao primario quando um run suceder no fallback."""
    mw = state.setdefault("model_watch", {})
    for name, chain in MODEL_FALLBACKS.items():
        row = query(
            "select a.id, a.adapter_config->>'model' from agents a "
            "where a.name = " + sql_lit(name) + " and a.status <> 'terminated' limit 1")
        if not row:
            continue
        agent_id, model = row[0]
        if model not in chain:
            continue
        # ultimas runs do agente (max 5)
        runs = query(
            "select status, left(coalesce(error,''),200) from heartbeat_runs "
            "where agent_id = " + sql_lit(agent_id) +
            " and status in ('succeeded','failed') order by created_at desc limit 5")
        if not runs:
            continue
        latest_status, latest_err = runs[0][0], runs[0][1]
        if latest_status == "succeeded":
            # modelo de fallback funcionou? reverter ao primario se nao estiver nele
            if model != chain[0] and mw.get(name, {}).get("swap_at"):
                query("update agents set adapter_config = jsonb_set(adapter_config,"
                      "'{model}', '\"" + chain[0] + "\"'::jsonb) where id = " + sql_lit(agent_id))
                mw.pop(name, None)
                send(f"🔁 {name}: revertida para {chain[0]} após sucesso no fallback.")
                log(f"watchdog: {name} revertida p/ {chain[0]}")
            mw.pop(name, None)
            continue
        # falha por grupo? conta falhas consecutivas com esse erro
        streak = 0
        for st, err in runs:
            if st == "failed" and GROUP_ERR in err:
                streak += 1
            else:
                break
        if streak < 2:
            continue
        idx = chain.index(model)
        if idx + 1 >= len(chain):
            # cadeia esgotada: failover cross-adapter — reatribui issues abertas
            # do agente morto para um agente Claude funcional (familia independente)
            if not mw.get(name, {}).get("exhausted"):
                mw.setdefault(name, {})["exhausted"] = True
                backup = FAILOVER_MAP.get(name)
                if backup:
                    brow = query(
                        "select id from agents where name = " + sql_lit(backup) +
                        " and status <> 'terminated' limit 1")
                    if brow:
                        n = query(
                            "update issues set assignee_agent_id = " + sql_lit(brow[0][0]) +
                            " where assignee_agent_id = " + sql_lit(agent_id) +
                            " and status in ('todo','in_progress','blocked','backlog')"
                            " returning identifier")
                        moved = ", ".join(r[0] for r in n) or "nenhuma"
                        send(f"🚨 {name}: {model} sem fallback — issues reatribuídas a {backup}: {moved}.")
                        log(f"watchdog FAILOVER {name} -> {backup}: {moved}")
                    else:
                        send(f"⚠️ {name}: {model} falhando por grupo, sem fallback e sem backup {backup}. Intervir.")
                else:
                    send(f"⚠️ {name}: modelo {model} falhando por grupo e não há mais fallbacks. Intervir.")
            continue
        # so troca uma vez por episodio
        if mw.get(name, {}).get("swap_to") == chain[idx + 1]:
            continue
        novo = chain[idx + 1]
        query("update agents set adapter_config = jsonb_set(adapter_config,"
              "'{model}', '\"" + novo + "\"'::jsonb) where id = " + sql_lit(agent_id))
        mw.setdefault(name, {})["swap_to"] = novo
        mw[name]["swap_at"] = time.time()
        send(f"🔁 {name}: {streak} falhas de grupo em {model} → trocando para {novo}.")
        log(f"watchdog: {name} {model} -> {novo} (streak={streak})")



DELIVERY_BATCH = {}  # project_name -> [(iid, ident, title), ...]


def flush_delivery_batch():
    """Envia entregas consolidadas por projeto (um e-mail por projeto). Cada issue e enviado
    uma unica vez: o ledger de paperclip-send-mail barra reenvio, e o lote e esvaziado antes
    do envio para que uma falha nunca vire reenvio em loop."""
    global DELIVERY_BATCH
    batch, DELIVERY_BATCH = DELIVERY_BATCH, {}
    for project, items in batch.items():
        items = [it for it in items if not already_delivered(it[1])]
        if not items:
            continue
        idents = ", ".join(i[1] for i in items)
        try:
            all_bodies = []
            all_attachments = []
            for iid, ident, title in items:
                _, body = find_best_deliverable(iid)
                materialized = materialize_deliverable(iid, ident, body)
                all_attachments.extend(collect_attachments(body) + materialized)
                all_bodies.append(f"## {ident} — {title}\n\n{body}\n\n{'—'*40}\n")
            consolidated = (f"Entregas consolidadas — Projeto: {project}\n"
                           f"Issues: {idents}\n"
                           f"{'='*60}\n\n" + "\n".join(all_bodies))
            fname = f"{OUTBOX}entrega-consolidada-{re.sub(r'[^0-9A-Za-z._-]+', '_', project)}.txt"
            with open(fname, "w", encoding="utf-8") as fh:
                fh.write(consolidated)
            # os [JMP-NNN] no assunto alimentam o ledger de envios
            subject = f"[Entregas Paperclip] {project[:60]} — {idents}"
            ok = True
            for dest in MAIL_TO:
                cmd = [SENDMAIL, dest, subject, fname]
                for att in all_attachments:
                    cmd.extend(["--attach", att])
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                if result.returncode != 0:
                    ok = False
                    log(f"erro envio consolidado {dest}: {result.stderr[:200]}")
                else:
                    log(f"entrega consolidada {project} -> {dest}")
            send(f"📬 Entregas '{project}' enviadas por e-mail: {idents}" if ok
                 else f"⚠️ Falha no envio de entregas '{project}' ({idents}). Não será reenviado automaticamente.")
        except Exception as exc:
            log(f"falha entrega {project} ({idents}): {exc}")
            send(f"⚠️ Falha ao montar entrega '{project}' ({idents}): {str(exc)[:150]}. Não será reenviado automaticamente.")


def tick(state):
    current = snapshot_issues()
    if not state["primed"]:
        state["issues"] = {k: v["status"] for k, v in current.items()}
        state["last_comment_at"] = query("select now()")[0][0]
        state["primed"] = True
        log(f"primeira execução: {len(current)} issues registrados")
    else:
        for iid, info in current.items():
            old = state["issues"].get(iid)
            new = info["status"]
            if old == new:
                continue
            head = f"{info['identifier']} — {info['title']}"
            if new in PENDING_STATUS:
                send(f"⏸ {head}\nStatus: {old or 'novo'} → {new}. Aguarda decisão.")
            elif new in CLOSED_STATUS:
                send(f"✅ {head}\nStatus: {old or 'novo'} → {new}.")
                # regra do operador (29/10): execucao de rotina (triagem/resumo) e operacional, nunca gera entrega
                if new == "done" and info.get("origin") == "routine_execution":
                    log(f"rotina concluida sem entrega: {info['identifier']}")
                elif new == "done":
                    proj = info.get("project", "(avulso)")
                    when = already_delivered(info["identifier"])
                    batch = DELIVERY_BATCH.setdefault(proj, [])
                    if when:
                        log(f"entrega ja enviada em {when}: {info['identifier']} - sem reenvio")
                        send(f"📭 {info['identifier']}: entrega já enviada em {when[:16]}. Fechamento sem reenvio.")
                    elif not any(it[0] == iid for it in batch):
                        batch.append((iid, info["identifier"], info["title"]))
                        log(f"entregavel enfileirado: {info['identifier']} (projeto: {proj})")
            else:
                send(f"ℹ️ {head}\nStatus: {old or 'novo'} → {new}.")
            state["issues"][iid] = new
        for stamp, ident, author in new_comments(state["last_comment_at"]):
            send(f"💬 {ident}: novo comentário de {author}. Abra no Paperclip para ler.")
            state["last_comment_at"] = stamp

    # Flush entregas consolidadas por projeto
    try:
        flush_delivery_batch()
    except Exception as exc:
        log(f"falha flush entregas: {exc}")

    state.setdefault("items", {})
    try:
        model_watchdog(state)
    except Exception as exc:
        log(f"watchdog erro: {exc}")
    today = time.strftime("%Y-%m-%d")
    if time.strftime("%H") >= "08" and state.get("digest_day") != today:
        send("🗂 Resumo diário dos projetos\n\n" + project_digest())
        state["digest_day"] = today
    for item in pending_interactions():
        state["items"][item["id"]] = item
        if item["id"] not in state["asked"]:
            if is_trivial_escalation(item):
                try:
                    auto_answer(item)
                    log(f"auto-respondida escalacao trivial {item['id']} ({item['identifier']})")
                except Exception as exc:
                    log(f"auto-resposta falhou {item['id']}: {exc}; encaminhando ao operador")
                    send_interaction(item, state)
            else:
                send_interaction(item, state)
    for ap in pending_approvals():
        if ap["id"] not in state["approvals"]:
            buttons = [[{"text": "✅ Aprovar", "callback_data": f"a|{ap['id']}|approve"},
                        {"text": "✖ Rejeitar", "callback_data": f"a|{ap['id']}|reject"}]]
            send(f"Aprovação pendente ({ap['type']}): {ap['id'][:8]}", buttons)
            state["approvals"][ap["id"]] = True
    # descarta interações que deixaram de estar pendentes
    open_ids = {i["id"] for i in pending_interactions()}
    for iid in list(state["items"].keys()):
        if iid not in open_ids:
            state["items"].pop(iid, None)
            state["drafts"].pop(iid, None)


def poll_telegram(state):
    updates = tg_call("getUpdates", {"offset": state["tg_offset"], "timeout": 0})
    for upd in updates:
        state["tg_offset"] = upd["update_id"] + 1
        if "callback_query" in upd:
            handle_callback(upd["callback_query"], state)
        elif "message" in upd:
            msg = upd["message"]
            if (msg.get("from") or {}).get("id") == ALLOWED:
                handle_text(msg, state)


def main():
    state = load_state()
    state.setdefault("items", {})
    log("bridge v8 iniciado" + ("" if BOARD_KEY else " (sem chave de board: ações de escrita desabilitadas)"))
    while True:
        try:
            tick(state)
            poll_telegram(state)
            save_state(state)
        except Exception as exc:
            log(f"erro: {exc}")
            try:
                save_state(state)
            except Exception:
                pass
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
