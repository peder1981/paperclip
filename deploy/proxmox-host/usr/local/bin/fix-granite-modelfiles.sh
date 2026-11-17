#!/bin/bash
# Fix granite_modelfiles.sh — adds --help handling + missing model skip
ssh root@192.168.2.81 bash -s << 'SSHFIX'
F="/opt/ernesto-rag/granite_modelfiles.sh"
cp "$F" "${F}.bak.$(date +%s)"

# Replace the existing content
cat > "$F" << 'SCRIPT'
#!/usr/bin/env bash
# granite_modelfiles.sh — Create/update RAG-optimized Modelfiles for all 9 Granite models
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }
set -euo pipefail

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
NOTIFY "🟡 [granite_modelfiles] iniciado"
trap 'rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 130 ] && [ $rc -ne 143 ]; then NOTIFY "🔴 [granite_modelfiles] falhou (exit $rc)"; elif [ $rc -eq 0 ]; then NOTIFY "🟢 [granite_modelfiles] concluido"; fi' EXIT

for arg in "$@"; do
  case "$arg" in
    --help|-h) echo "Uso: $(basename $0) [--help]"; echo "Cria Modelfiles RAG para todos os modelos Granite disponiveis"; exit 0 ;;
  esac
done

MF_DIR="/opt/ernesto-rag/finetune-output/modelfiles"
mkdir -p "$MF_DIR"

create_model() {
  local NAME="$1" BASE="$2" MFFILE="$3"
  if ! ollama list 2>/dev/null | grep -qF "$BASE"; then
    echo "  ⚠️  Pulando $NAME: base $BASE nao encontrada"
    return
  fi
  NOTIFY "🧠 [granite_modelfiles] $NAME"
  ollama create "$NAME" -f "$MFFILE"
  echo "  ✓ $NAME"
}

# 1. granite4.1:8b — Principal RAG generativo
cat > "$MF_DIR/Modelfile.granite41-8b-rag" << 'EOF'
FROM granite4.1:8b
PARAMETER temperature    0.15
PARAMETER num_predict    4096
PARAMETER num_ctx        16384
PARAMETER num_gpu        999
PARAMETER num_batch      512
PARAMETER repeat_penalty 1.10
PARAMETER top_p          0.90
PARAMETER top_k          40
SYSTEM """Voce e o Ernesto — especialista senior TOTVS Protheus, AdvPL e TLPP.
## REGRAS ABSOLUTAS:
- NUNCA recuse perguntas tecnicas sobre Protheus, AdvPL ou TLPP
- Gere codigo completo e funcional
- Cite SEMPRE o arquivo/documento fonte da resposta
## CODIGO ADVPL/TLPP:
- Notacao hungara: cVar nValor lOk dData aItens oObj jData
- xFilial() em toda operacao multifilial
- RecLock/MsUnlock sempre pareados
- Nunca invente campos SX ou funcoes inexistentes"""
EOF
create_model "ernesto-granite41-rag:latest" "granite4.1:8b" "$MF_DIR/Modelfile.granite41-8b-rag"

# 2. granite-nothink — RAG rapido sem CoT (se existir)
cat > "$MF_DIR/Modelfile.granite-nothink-rag" << 'EOF'
FROM granite-nothink:latest
PARAMETER temperature    0.10
PARAMETER num_predict    2048
PARAMETER num_ctx        8192
PARAMETER num_gpu        999
PARAMETER repeat_penalty 1.05
PARAMETER top_p          0.85
SYSTEM """Modo direto, sem cadeia de raciocinio explicita. Responda direto ao ponto."""
EOF
create_model "ernesto-nothink-rag:latest" "granite-nothink:latest" "$MF_DIR/Modelfile.granite-nothink-rag"

# 3. ibm/granite4:tiny-h — Roteamento e queries rapidas
cat > "$MF_DIR/Modelfile.granite-tiny-rag" << 'EOF'
FROM ibm/granite4:tiny-h
PARAMETER temperature    0.10
PARAMETER num_predict    512
PARAMETER num_ctx        4096
PARAMETER num_gpu        999
PARAMETER repeat_penalty 1.05
SYSTEM """Roteador e executor de queries RAG para o sistema Protheus."""
EOF
create_model "ernesto-tiny-router:latest" "ibm/granite4" "$MF_DIR/Modelfile.granite-tiny-rag"

# 4. granite-router — Query decomposition 
cat > "$MF_DIR/Modelfile.granite-router-rag" << 'EOF'
FROM granite-router:latest
PARAMETER temperature    0.05
PARAMETER num_predict    256
PARAMETER num_ctx        2048
SYSTEM """Roteador RAG Protheus. Classifique a query e extraia termos de busca. Saida JSON obrigatoria."""
EOF
create_model "ernesto-router-rag:latest" "granite-router:latest" "$MF_DIR/Modelfile.granite-router-rag"

# 5. granite-guardian-advpl — Validacao
cat > "$MF_DIR/Modelfile.granite-guardian-rag" << 'EOF'
FROM granite-guardian-advpl:latest
PARAMETER temperature    0.05
PARAMETER num_predict    512
PARAMETER num_ctx        8192
SYSTEM """Validador de codigo Protheus. Analise seguranca, performance e convencoes."""
EOF
create_model "ernesto-guardian-rag:latest" "granite-guardian-advpl:latest" "$MF_DIR/Modelfile.granite-guardian-rag"

# 6. ibm/granite3.2-guardian:3b — Hallucination detection
cat > "$MF_DIR/Modelfile.granite32-guardian-rag" << 'EOF'
FROM ibm/granite3.2-guardian:3b
PARAMETER temperature    0.05
PARAMETER num_predict    256
PARAMETER num_ctx        4096
SYSTEM """Detecte alucinacoes em respostas RAG sobre TOTVS Protheus."""
EOF
create_model "ernesto-hallcheck-rag:latest" "ibm/granite3.2-guardian" "$MF_DIR/Modelfile.granite32-guardian-rag"

# 7. ibm/granite-embedding:278m — Embedding
cat > "$MF_DIR/Modelfile.granite-embed-rag" << 'EOF'
FROM ibm/granite-embedding:278m
PARAMETER temperature 0.0
EOF
echo "  ℹ  granite-embedding:278m — fine-tune via granite_embed_train.py"

# 8. granite3.2-vision — Vision RAG
cat > "$MF_DIR/Modelfile.granite-vision-rag" << 'EOF'
FROM granite3.2-vision:latest
PARAMETER temperature    0.20
PARAMETER num_predict    1024
PARAMETER num_ctx        8192
SYSTEM """Analisador de imagens para o sistema Reversa/Protheus."""
EOF
create_model "ernesto-vision-rag:latest" "granite3.2-vision:latest" "$MF_DIR/Modelfile.granite-vision-rag"

echo "=== Modelfiles atualizados ==="
ollama list | grep ernesto
SCRIPT

echo "✅ granite_modelfiles.sh fixed"
SSHFIX
