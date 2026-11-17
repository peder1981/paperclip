#!/bin/bash
CONTAINER=101
HOST_IP="192.168.2.81"

# Esperar o container ready
until pct status $CONTAINER | grep -q "running"; do
    echo "Aguardando container $CONTAINER..."
    sleep 2
done

echo "Container $CONTAINER está rodando."

# Função para iniciar um serviço no container
start_service() {
    local service=$1
    local cmd=$2
    local log=$3
    echo "Iniciando $service..."
    pct exec $CONTAINER -- bash -c '$cmd > $log 2>&1 & disown'
    sleep 2
}

# Iniciar serviços na sequência correta
# 1. ChromaDB
pct exec $CONTAINER -- bash -c '/mnt/ernesto-data/chroma_db/ernesto-rag-venv/bin/chroma run --host 127.0.0.1 --port 17878 > /tmp/chroma.log 2>&1 & disown'
sleep 3

# 2. Mem0
pct exec $CONTAINER -- bash -c '/mnt/ernesto-data/chroma_db/ernesto-rag-venv/bin/python3 /opt/ernesto-rag/mem0_proxy.py > /tmp/mem0.log 2>&1 & disown'
sleep 3

# 3. MCP SSE
pct exec $CONTAINER -- bash -c '/mnt/ernesto-data/chroma_db/ernesto-rag-venv/bin/python3 /opt/ernesto-rag/mcp_sse_server.py > /tmp/mcp.log 2>&1 & disown'
sleep 3

# 4. RAG Proxy (requer Ollama, vamos pular por enquanto ou iniciar ollama)
# Ollama需要先启动
pct exec $CONTAINER -- bash -c '/usr/local/bin/ollama serve > /tmp/ollama.log 2>&1 & disown'
sleep 5
pct exec $CONTAINER -- bash -c '/mnt/ernesto-data/chroma_db/ernesto-rag-venv/bin/python3 -m uvicorn rag_proxy:app --host 0.0.0.0 --port 9080 > /tmp/rag.log 2>&1 & disown'
sleep 3

echo "Todos os serviços iniciados no container $CONTAINER."

# Manter o script rodando para monitorar
while true; do
    sleep 60
done
