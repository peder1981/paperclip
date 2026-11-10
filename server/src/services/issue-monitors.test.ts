import { describe, expect, it } from "vitest";
import {
  AGENT_MONITOR_DEFAULT_TIMEOUT_MS,
  AGENT_MONITOR_MAX_TIMEOUT_MS,
  applyActorMonitorScheduledBy,
} from "./issue-monitors.js";
import { normalizeIssueExecutionPolicy } from "./issue-execution-policy.js";

const NEXT_CHECK_AT = "2026-11-10T12:00:00.000Z";

function policyWithMonitor(monitor: Record<string, unknown>) {
  return normalizeIssueExecutionPolicy({
    monitor: { nextCheckAt: NEXT_CHECK_AT, notes: "check", ...monitor },
  });
}

describe("applyActorMonitorScheduledBy — deferência limitada para agentes", () => {
  it("injeta timeoutAt default e escalate_to_board quando o agente não informa limites", () => {
    const result = applyActorMonitorScheduledBy(policyWithMonitor({}), "agent");
    const monitor = result?.monitor;
    expect(monitor?.scheduledBy).toBe("assignee");
    expect(monitor?.timeoutAt).toBe(
      new Date(Date.parse(NEXT_CHECK_AT) + AGENT_MONITOR_DEFAULT_TIMEOUT_MS).toISOString(),
    );
    expect(monitor?.recoveryPolicy).toBe("escalate_to_board");
  });

  it("mantém timeoutAt e recoveryPolicy explícitos dentro do teto", () => {
    const timeoutAt = new Date(Date.parse(NEXT_CHECK_AT) + 60 * 60 * 1000).toISOString();
    const result = applyActorMonitorScheduledBy(
      policyWithMonitor({ timeoutAt, recoveryPolicy: "wake_owner", maxAttempts: 3 }),
      "agent",
    );
    expect(result?.monitor?.timeoutAt).toBe(timeoutAt);
    expect(result?.monitor?.recoveryPolicy).toBe("wake_owner");
    expect(result?.monitor?.maxAttempts).toBe(3);
  });

  it("limita timeoutAt explícito ao teto máximo após nextCheckAt", () => {
    const farFuture = new Date(Date.parse(NEXT_CHECK_AT) + 30 * 24 * 60 * 60 * 1000).toISOString();
    const result = applyActorMonitorScheduledBy(
      policyWithMonitor({ timeoutAt: farFuture }),
      "agent",
    );
    expect(result?.monitor?.timeoutAt).toBe(
      new Date(Date.parse(NEXT_CHECK_AT) + AGENT_MONITOR_MAX_TIMEOUT_MS).toISOString(),
    );
  });

  it("não altera monitores agendados pelo board", () => {
    const result = applyActorMonitorScheduledBy(policyWithMonitor({}), "user");
    const monitor = result?.monitor;
    expect(monitor?.scheduledBy).toBe("board");
    expect(monitor?.timeoutAt).toBeNull();
    expect(monitor?.recoveryPolicy).toBeNull();
  });

  it("retorna policy nula intacta", () => {
    expect(applyActorMonitorScheduledBy(null, "agent")).toBeNull();
  });
});
