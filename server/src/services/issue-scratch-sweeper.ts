import { readdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { issues } from "@paperclipai/db";
import type { Db } from "@paperclipai/db";

/**
 * Agentes criam diretórios de trabalho por issue dentro de raízes
 * compartilhadas (ex.: /var/lib/paperclip/tecnico/JMP-261/). Nenhum lifecycle
 * os remove quando a issue termina, e cada um pode carregar clones de
 * repositório de vários GB. Este sweeper remove o diretório de uma issue
 * terminal (done/cancelled) depois de um período de graça, usando o
 * identificador da issue como nome do diretório.
 *
 * Segurança:
 * - Só aceita nomes que casam com o padrão de identificador de issue
 *   (PREFIX-N). Diretórios com outros nomes nunca são tocados.
 * - O diretório só é removido quando TODOS os issues com aquele
 *   identificador estão em estado terminal.
 * - O mtime do diretório precisa ser mais velho que o grace period —
 *   um agente escrevendo agora mantém o mtime fresco.
 * - varreduras são limitadas a uma por minIntervalMs.
 */

const ISSUE_IDENTIFIER_RE = /^[A-Za-z]{1,12}-\d{1,10}$/;
const TERMINAL_ISSUE_STATUSES = new Set(["done", "cancelled"]);
const DEFAULT_MIN_INTERVAL_MS = 60 * 60 * 1000;

export type IssueScratchSweepResult = {
  roots: number;
  candidates: number;
  deleted: number;
  keptActive: number;
  keptFresh: number;
  keptUnknown: number;
  errors: number;
  throttled: boolean;
};

function emptyResult(throttled: boolean): IssueScratchSweepResult {
  return {
    roots: 0,
    candidates: 0,
    deleted: 0,
    keptActive: 0,
    keptFresh: 0,
    keptUnknown: 0,
    errors: 0,
    throttled,
  };
}

export function createIssueScratchSweeper(opts: {
  db: Db;
  roots: string[];
  graceMs: number;
  now?: () => Date;
  minIntervalMs?: number;
}) {
  const now = opts.now ?? (() => new Date());
  const minIntervalMs = opts.minIntervalMs ?? DEFAULT_MIN_INTERVAL_MS;
  let lastSweepAtMs = 0;

  async function allIssuesTerminal(identifier: string): Promise<boolean | null> {
    const rows = await opts.db
      .select({ status: issues.status })
      .from(issues)
      .where(eq(issues.identifier, identifier));
    if (rows.length === 0) return null;
    return rows.every((row) => TERMINAL_ISSUE_STATUSES.has(row.status));
  }

  async function sweep(): Promise<IssueScratchSweepResult> {
    const startedAtMs = now().getTime();
    if (startedAtMs - lastSweepAtMs < minIntervalMs) {
      return emptyResult(true);
    }
    lastSweepAtMs = startedAtMs;

    const result = emptyResult(false);
    result.roots = opts.roots.length;

    for (const root of opts.roots) {
      let entries;
      try {
        entries = await readdir(root, { withFileTypes: true });
      } catch {
        result.errors += 1;
        continue;
      }
      for (const entry of entries) {
        if (!entry.isDirectory() || !ISSUE_IDENTIFIER_RE.test(entry.name)) {
          continue;
        }
        result.candidates += 1;
        const dirPath = join(root, entry.name);
        try {
          const info = await stat(dirPath);
          if (startedAtMs - info.mtimeMs < opts.graceMs) {
            result.keptFresh += 1;
            continue;
          }
          const terminal = await allIssuesTerminal(entry.name);
          if (terminal === null) {
            result.keptUnknown += 1;
            continue;
          }
          if (!terminal) {
            result.keptActive += 1;
            continue;
          }
          await rm(dirPath, { recursive: true, force: true });
          result.deleted += 1;
        } catch {
          result.errors += 1;
        }
      }
    }
    return result;
  }

  return { sweep };
}
