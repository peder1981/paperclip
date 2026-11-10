import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, rm, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { companies, createDb, issues } from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "../__tests__/helpers/embedded-postgres.js";
import { createIssueScratchSweeper } from "./issue-scratch-sweeper.js";

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

describeEmbeddedPostgres("issue-scratch-sweeper", () => {
  let db!: ReturnType<typeof createDb>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;
  let root = "";
  let companyId = "";
  let seq = 0;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-scratch-sweeper-");
    db = createDb(tempDb.connectionString);
    root = await mkdtemp(join(tmpdir(), "scratch-sweep-"));
    const company = await db
      .insert(companies)
      .values({
        name: `Scratch Sweeper ${randomUUID()}`,
        issuePrefix: `SW${randomUUID().slice(0, 4).toUpperCase()}`,
      })
      .returning()
      .then((rows) => rows[0]!);
    companyId = company.id;
  }, 30_000);

  afterAll(async () => {
    if (root) await rm(root, { recursive: true, force: true });
    await tempDb?.cleanup();
  });

  async function insertIssue(identifier: string, status: string) {
    seq += 1;
    await db.insert(issues).values({
      companyId,
      identifier: `${identifier}-${seq}`,
      title: `scratch ${identifier}`,
      status,
    });
    return `${identifier}-${seq}`;
  }

  async function makeDir(name: string, ageMs: number) {
    const dir = join(root, name);
    await mkdir(dir, { recursive: true });
    const past = new Date(Date.now() - ageMs);
    await utimes(dir, past, past);
    return dir;
  }

  function sweeper(graceMs = 60_000) {
    return createIssueScratchSweeper({
      db: db as never,
      roots: [root],
      graceMs,
      minIntervalMs: 0,
    });
  }

  it("remove diretório de issue done antiga e preserva issue ativa e fresca", async () => {
    const doneId = await insertIssue("SW", "done");
    const activeId = await insertIssue("SW", "in_progress");
    const freshId = await insertIssue("SW", "done");
    const cancelledId = await insertIssue("SW", "cancelled");

    const doneDir = await makeDir(doneId, 120_000);
    const activeDir = await makeDir(activeId, 120_000);
    const freshDir = await makeDir(freshId, 1_000);
    const cancelledDir = await makeDir(cancelledId, 120_000);

    const res = await sweeper().sweep();

    expect(res.deleted).toBe(2);
    expect(res.keptActive).toBe(1);
    expect(res.keptFresh).toBe(1);
    await expect(
      import("node:fs/promises").then((fs) => fs.stat(doneDir)),
    ).rejects.toThrow();
    await expect(
      import("node:fs/promises").then((fs) => fs.stat(cancelledDir)),
    ).rejects.toThrow();
    await expect(
      import("node:fs/promises").then((fs) => fs.stat(activeDir)),
    ).resolves.toBeTruthy();
    await expect(
      import("node:fs/promises").then((fs) => fs.stat(freshDir)),
    ).resolves.toBeTruthy();
  });

  it("não remove diretório sem issue correspondente nem nome fora do padrão", async () => {
    const orphanDir = await makeDir("SW-999999", 120_000);
    const oddDir = await makeDir("random-folder", 120_000);

    const res = await sweeper().sweep();

    // O teste anterior deixou 2 diretórios vivos (issue ativa e done fresca);
    // ambos voltam a ser candidatos nesta varredura.
    expect(res.candidates).toBe(3);
    expect(res.keptUnknown).toBe(1);
    expect(res.keptActive).toBe(1);
    expect(res.keptFresh).toBe(1);
    expect(res.deleted).toBe(0);
    const fs = await import("node:fs/promises");
    await expect(fs.stat(orphanDir)).resolves.toBeTruthy();
    await expect(fs.stat(oddDir)).resolves.toBeTruthy();
  });
});
