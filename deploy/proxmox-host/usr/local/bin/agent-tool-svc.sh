#!/bin/bash
# Uso: agent-tool-svc.sh <nome> — somente leitura
pct exec 101 -- systemctl is-active "$1" 2>&1
