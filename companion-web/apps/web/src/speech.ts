type SpeechRec = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  processLocally?: boolean;
  onresult: ((ev: { results: ArrayLike<{ 0: { transcript: string }; isFinal: boolean }> }) => void) | null;
  onerror: ((ev: { error: string }) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
};

type SpeechRecCtor = new () => SpeechRec;

function getSpeechRecognition(): SpeechRecCtor | null {
  if (typeof window === "undefined") return null;
  const w = window as unknown as {
    SpeechRecognition?: SpeechRecCtor;
    webkitSpeechRecognition?: SpeechRecCtor;
  };
  return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null;
}

export function speechSupported(): boolean {
  return !!getSpeechRecognition();
}

export async function preferOnDevice(rec: SpeechRec): Promise<boolean> {
  const anyRec = rec as SpeechRec & {
    available?: (opts: { processLocally: boolean; langs: string[] }) => Promise<string>;
  };
  if (typeof anyRec.available !== "function") return false;
  try {
    const status = await anyRec.available({ processLocally: true, langs: ["en-US"] });
    if (status === "available") {
      rec.processLocally = true;
      return true;
    }
  } catch {
    /* cloud fallback */
  }
  return false;
}

export function startListening(opts: {
  onPartial: (t: string) => void;
  onFinal: (t: string) => void;
  onError: (e: string) => void;
}): { stop: () => void } | null {
  const Ctor = getSpeechRecognition();
  if (!Ctor) {
    opts.onError("Speech recognition not available in this browser");
    return null;
  }
  const rec = new Ctor();
  rec.continuous = false;
  rec.interimResults = true;
  rec.lang = "en-US";
  void preferOnDevice(rec);
  rec.onresult = (ev) => {
    let interim = "";
    let final = "";
    for (let i = 0; i < ev.results.length; i++) {
      const r = ev.results[i]!;
      if (r.isFinal) final += r[0].transcript;
      else interim += r[0].transcript;
    }
    if (interim) opts.onPartial(interim);
    if (final) opts.onFinal(final.trim());
  };
  rec.onerror = (e) => opts.onError(e.error);
  rec.onend = () => {};
  rec.start();
  return { stop: () => rec.stop() };
}

export function speak(text: string, enabled: boolean) {
  if (typeof window === "undefined") return;
  if (!enabled || !text || !window.speechSynthesis) return;
  window.speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.rate = 1;
  window.speechSynthesis.speak(u);
}
