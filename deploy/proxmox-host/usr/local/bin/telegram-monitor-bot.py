#!/usr/bin/env python3
"""
Proxmox Homelab Telegram Monitor Bot
Integrates with Spark-X2.5 for AI-powered analysis
"""

import os
import sys
import json
import asyncio
import logging
from datetime import datetime
from pathlib import Path

# Try to import telethon (faster than python-telegram-bot)
try:
    from telethon import TelegramClient, events
    HAS_TELETHON = True
except ImportError:
    try:
        from telegram import Bot, Update
        from telegram.ext import ApplicationBuilder, ContextTypes, CommandHandler
        HAS_TELETHON = False
    except ImportError:
        print("❌ Telegram library not found. Installing...")
        os.system("pip install telethon --quiet")
        from telethon import TelegramClient, events
        HAS_TELETHON = True

# Configuration
TELEGRAM_TOKEN = os.getenv('TELEGRAM_TOKEN', '')
TELEGRAM_CHAT_IDS = os.getenv('TELEGRAM_CHAT_IDS', '').split(',')
SPARK_AVAILABLE = os.path.exists('/tmp/llama.cpp/build/bin/llama-cli')
MONITOR_SCRIPT = '/usr/local/bin/monitor-proxmox.sh'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ProxmoxMonitorBot:
    def __init__(self):
        self.client = TelegramClient(
            '/root/.proxmox_bot.session',
            api_id='YOUR_API_ID',  # Configure this
            api_hash='YOUR_API_HASH'  # Configure this
        ) if HAS_TELETHON else None
        
    async def get_proxmox_status(self):
        """Get current Proxmox status"""
        import subprocess
        
        result = {
            'timestamp': datetime.now().isoformat(),
            'lxc_status': {},
            'host_resources': {}
        }
        
        # Get LXC status
        for lxc_id in ['100', '101', '103', '104', '105', '106', '107', '108', '109']:
            try:
                status = await self._run_command(f'pct status {lxc_id}')
                config = await self._run_command(f'pct config {lxc_id}')
                result['lxc_status'][lxc_id] = {
                    'status': status.split(':')[1].strip() if ':' in status else 'unknown',
                    'config': config
                }
            except:
                result['lxc_status'][lxc_id] = {'status': 'error'}
        
        # Get host resources
        try:
            uptime = await self._run_command('uptime')
            memory = await self._run_command('free -h')
            disk = await self._run_command('df -h /')
            
            result['host_resources'] = {
                'uptime': uptime,
                'memory': memory,
                'disk': disk
            }
        except:
            pass
        
        return result
    
    async def ai_analyze(self, status_data):
        """Use Spark-X2.5 to analyze status"""
        if not SPARK_AVAILABLE:
            return "⚠️ Spark-X2.5 não disponível"
        
        import subprocess
        
        report = json.dumps(status_data, indent=2)
        prompt = f"""Analise este relatório de infraestrutura Proxmox e dê recomendaçõesprioritárias:

{report}

Responda com:
1. Problemas críticos (se houver)
2. Recomendações de melhoria
3. Status geral (🟢 bom / 🟡 atenção / 🔴 crítico)
"""
        
        try:
            result = await self._run_command(
                f'/tmp/llama.cpp/build/bin/llama-cli '
                f'-m /opt/models/Spark-X2.5-1.7B-GGUF/Spark-X2.5-1.7B-Q4_K_M.gguf '
                f'-p "<|user|>\n{prompt}<|end|>\n<|assistant|>\n" '
                f'--temp 0.7 --top-p 0.9 -n 800 --no-mmap'
            )
            return result
        except Exception as e:
            logger.error(f"AI analysis failed: {e}")
            return "⚠️ Análise AI falhou"
    
    async def _run_command(self, cmd):
        """Run shell command"""
        process = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        if process.returncode != 0:
            raise Exception(stderr.decode()[:200])
        return stdout.decode().strip()
    
    async def start(self):
        """Start the bot"""
        logger.info("🚀 Starting Proxmox Monitor Bot...")
        
        # Get initial status
        status = await self.get_proxmox_status()
        
        # Send welcome message
        for chat_id in TELEGRAM_CHAT_IDS:
            if chat_id.strip():
                await self.client.send_message(
                    chat_id.strip(),
                    "🤖 Proxmox Homelab Monitor Bot online!\n\n"
                    "Comandos disponíveis:\n"
                    "/status - Status atual dos LXC's\n"
                    "/ai - Análise com Spark-X2.5\n"
                    "/alerts - Configurar alertas\n"
                    "/help - Ajuda"
                )
        
        # Register handlers
        @self.client.on(events.NewMessage(pattern='(?i)/status'))
        async def handler_status(event):
            status = await self.get_proxmox_status()
            await event.reply(self._format_status(status))
        
        @self.client.on(events.NewMessage(pattern='(?i)/ai'))
        async def handler_ai(event):
            status = await self.get_proxmox_status()
            analysis = await self.ai_analyze(status)
            await event.reply(f"🤖 **Análise Spark-X2.5:**\n\n{analysis}")
        
        @self.client.on(events.NewMessage(pattern='(?i)/help'))
        async def handler_help(event):
            await event.reply(
                "📚 **Proxmox Monitor Bot - Ajuda**\n\n"
                "/status - Status dos LXC's (100-109)\n"
                "/ai - Análise inteligente com Spark-X2.5\n"
                "/alerts - Configurar limiares de alerta\n"
                "/resources - Recursos do host\n"
                "/logs - Últimos logs\n"
                "/help - Esta mensagem"
            )
        
        logger.info("✅ Bot started successfully!")
        await self.client.run_until_disconnected()
    
    def _format_status(self, status):
        """Format status for Telegram"""
        msg = "📊 **Proxmox Homelab Status**\n"
        msg += f"🕐 {status['timestamp']}\n\n"
        
        for lxc_id, data in status['lxc_status'].items():
            icon = "✅" if data['status'] == 'running' else "🚨"
            msg += f"{icon} LXC {lxc_id}: {data['status']}\n"
        
        return msg

async def main():
    bot = ProxmoxMonitorBot()
    await bot.start()

if __name__ == '__main__':
    asyncio.run(main())
