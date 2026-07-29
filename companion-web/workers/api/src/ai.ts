import { BRIEF_PROMPT, CHECKIN_PROMPT, MIDDAY_PROMPT } from "@companion/shared";

const MODEL_MAP: Record<string, string> = {
  "checkin-fast": "openai/gpt-4o-mini",
  "brief-fast": "openai/gpt-4o-mini",
};

export async function completeJson(opts: {
  baseUrl: string;
  apiKey: string;
  logicalModel: string;
  system: string;
  user: string;
}): Promise<{ text: string; model: string }> {
  const model = MODEL_MAP[opts.logicalModel] ?? opts.logicalModel;
  const res = await fetch(`${opts.baseUrl.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${opts.apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://companion.local",
      "X-Title": "ADHD Companion",
    },
    body: JSON.stringify({
      model,
      temperature: 0.4,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: opts.system },
        { role: "user", content: opts.user },
      ],
    }),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`AI error ${res.status}: ${err.slice(0, 400)}`);
  }
  const data = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const text = data.choices?.[0]?.message?.content ?? "{}";
  return { text, model };
}

export function promptForEngine(engine: "checkin" | "brief" | "midday"): string {
  if (engine === "brief") return BRIEF_PROMPT;
  if (engine === "midday") return MIDDAY_PROMPT;
  return CHECKIN_PROMPT;
}

/** Local template fallback when no API key — still shame-free. */
export function localFallback(engine: "checkin" | "brief" | "midday", userMessage?: string): string {
  if (engine === "brief") {
    return JSON.stringify({
      headline: "You showed up today",
      accomplishments: [
        userMessage?.trim()
          ? `You noted: ${userMessage.trim().slice(0, 120)}`
          : "You opened reflection — that counts as orientation.",
      ],
      priority_outcomes: [],
      gentle_close: "Tomorrow is a fresh start.",
      gratitude_prompt: "One thing that went okay today?",
      copy_ok_for_user: true,
    });
  }
  if (engine === "midday") {
    return JSON.stringify({
      reply: "Quick time check — how's the thing you planned going? On it, sidetracked, or need overwhelm mode?",
      suggest_reprioritize: true,
    });
  }
  return JSON.stringify({
    reply:
      "What's the easiest thing you can do today — or what can you finish fastest for a quick win? You can also keep yesterday's list if it still fits.",
    priorities: [],
    needs_user_input: true,
    tone_flags: {
      shame_free: true,
      no_skipped_framing: true,
      neutral_not_forced_positive: true,
    },
  });
}
