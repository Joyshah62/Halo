// Plays steps in order: reveals each explanation step and speaks it before moving on.
// Sync is per step: a step waits for its audio to finish.
import type { Step } from "../shared/types";

const estimateMs = (s: string) => 400 + s.split(/\s+/).filter(Boolean).length * 330;

export class Player {
  private queue: Step[] = [];
  private running = false;
  private ended = false;
  private resolveAll: (() => void) | null = null;
  private current: HTMLAudioElement | null = null;
  private stopped = false;
  private abort = new AbortController();
  onStep: (step: Step) => void = () => {};

  constructor(private voiceOut: boolean) {}

  push(step: Step) {
    this.queue.push(step);
    if (!this.running) this.run();
  }
  /** No more steps are coming; resolves when playback drains. */
  finish(): Promise<void> {
    this.ended = true;
    if (!this.running && !this.queue.length) return Promise.resolve();
    return new Promise((r) => (this.resolveAll = r));
  }
  stop() {
    this.stopped = true;
    this.abort.abort();
    this.resolveAll?.();
    this.queue = [];
    this.current?.pause();
    try { speechSynthesis.cancel(); } catch {}
  }

  private async run() {
    this.running = true;
    while (this.queue.length && !this.stopped) {
      const step = this.queue.shift()!;
      this.onStep(step);
      try { await this.playStep(step); } catch (e) { console.warn("[halo] step failed", e); }
      console.debug("[halo] step done", step.index);
      await new Promise((r) => setTimeout(r, 180));
    }
    this.running = false;
    if (this.ended || this.stopped) this.resolveAll?.();
  }

  private async playStep(step: Step) {
    if (step.audio && this.voiceOut) {
      const audio = new Audio(`data:audio/mpeg;base64,${step.audio}`);
      this.current = audio;
      const durationMs = await new Promise<number>((res) => {
        const t = setTimeout(() => res(estimateMs(step.say)), 1500);
        audio.addEventListener("loadedmetadata", () => { clearTimeout(t); res(isFinite(audio.duration) ? audio.duration * 1000 : estimateMs(step.say)); }, { once: true });
      });
      if (this.stopped) return;
      const ended = new Promise<void>((res) => {
        audio.addEventListener("pause", () => res(), { once: true });
        audio.addEventListener("ended", () => res(), { once: true });
        audio.addEventListener("error", () => res(), { once: true });
        setTimeout(res, durationMs + 4000);
      });
      try { await audio.play(); } catch (e) { console.warn("[halo] autoplay blocked", e); }
      await ended;
      return;
    }
    const durationMs = estimateMs(step.say);
    if (this.voiceOut && "speechSynthesis" in window) {
      const u = new SpeechSynthesisUtterance(step.say);
      u.rate = 1.05;
      const spoken = new Promise<void>((res) => { u.onend = () => res(); u.onerror = () => res(); setTimeout(res, durationMs * 2.5); });
      speechSynthesis.speak(u);
      await spoken;
    } else {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, durationMs);
        this.abort.signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
      });
    }
  }
}
