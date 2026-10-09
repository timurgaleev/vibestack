/**
 * Compliance spec: the expected behavioral sequence for one rule or skill.
 *
 * A spec names its source `.md` (a rule under config/claude/rules/ or a skill
 * under skills/), one task, and the steps a compliant session shows in its
 * tool calls. The same task runs at three prompt levels:
 *
 *   supportive — names the rule and what it asks for
 *   neutral    — the bare task; the rule is only in the loaded context
 *   competing  — the task plus pressure that pulls against the rule
 *
 * Steps are graded from tool calls. A `match` step is deterministic (tool name
 * plus a regex over one input field) and could be enforced by a PreToolUse
 * hook; a `judge` step needs an LLM verdict over the transcript and cannot.
 */
import * as fs from "node:fs";
import * as path from "node:path";

export const LEVELS = ["supportive", "neutral", "competing"] as const;
export type Level = (typeof LEVELS)[number];

export interface StepMatch {
  /** Regex over the tool name, anchored: "Edit|Write" matches either. */
  tool: string;
  /** Tool-input field the pattern reads (file paths are sandbox-relative). */
  field: string;
  /** Regex over that field. */
  pattern: string;
}

export interface Step {
  id: string;
  /** required: must occur at least once. forbidden: must never occur. */
  kind: "required" | "forbidden";
  desc: string;
  /** Task progress (did the agent do the work at all), not rule behavior. */
  task?: boolean;
  match?: StepMatch;
  /** Question for the LLM judge when no tool-call pattern can decide it. */
  judge?: string;
}

export interface Spec {
  id: string;
  /** Repo-relative rule or skill `.md` the behavior comes from. */
  source: string;
  /** Short rule name the supportive prompt cites. */
  rule: string;
  /** Skill installed into the sandbox (skill specs only). */
  skill?: string;
  /** Named fixture from fixtures.ts that seeds the sandbox. */
  fixture: string;
  task: string;
  /** What the supportive prompt reminds the agent of. */
  ruleHint: string;
  /** Pressure appended at the competing level. */
  pressure: string;
  /** Per-level prompt overrides; otherwise built from task/ruleHint/pressure. */
  prompts?: Partial<Record<Level, string>>;
  steps: Step[];
  /** Pairs [before, after]: if `after` occurs, `before` must occur first. */
  order?: Array<[string, string]>;
  maxTurns?: number;
  allowedTools?: string[];
  /** Free text for spec readers: how the harness behaves, known limits. Not graded. */
  notes?: string;
}

const HERE = path.dirname(new URL(import.meta.url).pathname);
export const SPEC_DIR = path.join(HERE, "specs");
export const REPO = path.join(HERE, "..", "..", "..");

export function validateSpec(raw: any, fixtures: string[]): string[] {
  const errs: string[] = [];
  const need = ["id", "source", "rule", "fixture", "task", "ruleHint", "pressure"];
  for (const k of need) if (typeof raw?.[k] !== "string" || !raw[k]) errs.push(`missing ${k}`);
  if (errs.length) return errs;
  if (!fs.existsSync(path.join(REPO, raw.source))) errs.push(`source not found: ${raw.source}`);
  if (raw.skill && !fs.existsSync(path.join(REPO, "skills", raw.skill, "SKILL.md"))) {
    errs.push(`skill not found: ${raw.skill}`);
  }
  if (!fixtures.includes(raw.fixture)) errs.push(`unknown fixture: ${raw.fixture}`);
  if (!Array.isArray(raw.steps) || raw.steps.length === 0) errs.push("steps must be a non-empty array");
  const ids = new Set<string>();
  for (const s of raw.steps ?? []) {
    if (!s?.id) { errs.push("step without id"); continue; }
    if (ids.has(s.id)) errs.push(`duplicate step id: ${s.id}`);
    ids.add(s.id);
    if (s.kind !== "required" && s.kind !== "forbidden") errs.push(`${s.id}: kind must be required|forbidden`);
    if (!s.match === !s.judge) errs.push(`${s.id}: exactly one of match or judge`);
    if (s.match) {
      for (const k of ["tool", "field", "pattern"]) {
        if (typeof s.match[k] !== "string") errs.push(`${s.id}: match.${k} missing`);
      }
      try { new RegExp(s.match.pattern); new RegExp(`^(?:${s.match.tool})$`); } catch (e) {
        errs.push(`${s.id}: bad regex (${(e as Error).message})`);
      }
    }
  }
  for (const pair of raw.order ?? []) {
    for (const id of pair) {
      if (!ids.has(id)) errs.push(`order references unknown step: ${id}`);
      else {
        const s = raw.steps.find((s: Step) => s.id === id);
        if (s.kind !== "required" || !s.match) errs.push(`order step must be a required match step: ${id}`);
      }
    }
  }
  for (const k of Object.keys(raw.prompts ?? {})) {
    if (!(LEVELS as readonly string[]).includes(k)) errs.push(`unknown prompt level: ${k}`);
  }
  return errs;
}

export function loadSpecs(fixtures: string[], dir = SPEC_DIR): Spec[] {
  const specs: Spec[] = [];
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
    const raw = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
    const errs = validateSpec(raw, fixtures);
    if (errs.length) throw new Error(`${f}: ${errs.join("; ")}`);
    specs.push(raw as Spec);
  }
  return specs;
}

export function buildPrompt(spec: Spec, level: Level): string {
  const override = spec.prompts?.[level];
  if (override) return override;
  // The level text goes after the task so a task that opens with a slash
  // command still resolves as one.
  switch (level) {
    case "supportive":
      return `${spec.task}\n\nFollow the ${spec.rule} rule: ${spec.ruleHint}`;
    case "neutral":
      return spec.task;
    case "competing":
      return `${spec.task}\n\n${spec.pressure}`;
  }
}
