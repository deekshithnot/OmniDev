import React, { useEffect, useRef, useState } from "react";
import { streamChat } from "./services/api";
import { openPaint } from "./services/desktop";

const styles = [
  ["beginner", "Beginner friendly"],
  ["exam", "Exam focused"],
  ["detailed", "Detailed explanation"],
  ["advanced", "Advanced"],
];

export default function TeachMode({ provider, model, onSetup }) {
  const [topic, setTopic] = useState("");
  const [style, setStyle] = useState("beginner");
  const [lesson, setLesson] = useState("");
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [speech, setSpeech] = useState("idle");
  const utterance = useRef(null);

  useEffect(() => () => {
    if ("speechSynthesis" in window) window.speechSynthesis.cancel();
  }, []);

  async function createLesson(event) {
    event.preventDefault();
    if (!topic.trim() || busy) return;
    if (!model?.trim()) { setError("Choose a chat model before generating a lesson."); onSetup?.(); return; }
    setBusy(true); setError(""); setLesson(""); setDraft("");
    let answer = "";
    try {
      await streamChat({
        provider, model,
        messages: [
          { role: "system", content: "You are OmniDev Teach Mode, a precise visual instructor. Teach the requested topic with a short overview, prerequisites if needed, then 4 to 7 numbered board steps. For each step include a clear heading, exactly what to draw in Microsoft Paint using simple shapes/arrows/labels, and a concise explanation to say aloud. Finish with a worked example and 3 quick check questions. Use Markdown, avoid tables, keep each drawing instruction practical for a blank Paint canvas. Do not claim you can control the user's mouse or draw automatically." },
          { role: "user", content: `Teach me "${topic.trim()}" in a ${style} style. Make the lesson coherent and suitable to follow on a Paint canvas.` }
        ]
      }, chunk => { answer += chunk; setDraft(answer); });
      if (!answer.trim()) throw new Error("The selected model returned an empty lesson.");
      setLesson(answer);
    } catch (e) { setError(e.message || "Could not generate lesson."); }
    finally { setBusy(false); }
  }

  function speak(text = lesson) {
    if (!text || !("speechSynthesis" in window)) {
      setError("Speech narration is not supported by this browser/runtime.");
      return;
    }
    window.speechSynthesis.cancel();
    const clean = text.replace(/[#*_\x60>-]/g, " ").replace(/\n+/g, ". ");
    const utteranceValue = new SpeechSynthesisUtterance(clean);
    utteranceValue.rate = 0.96;
    utteranceValue.onstart = () => setSpeech("speaking");
    utteranceValue.onend = () => setSpeech("idle");
    utteranceValue.onerror = () => setSpeech("idle");
    utterance.current = utteranceValue;
    window.speechSynthesis.speak(utteranceValue);
  }
  function pause() { window.speechSynthesis.pause(); setSpeech("paused"); }
  function resume() { window.speechSynthesis.resume(); setSpeech("speaking"); }
  function stop() { window.speechSynthesis.cancel(); setSpeech("idle"); }

  const displayed = lesson || draft;
  return <div className="teach-mode">
    <div className="teach-intro">
      <span className="eyebrow">VISUAL LEARNING / PAINT COMPANION</span>
      <h2>Learn it by drawing it.</h2>
      <p>OmniDev builds a step-by-step board lesson, opens Microsoft Paint, and can narrate the explanation while you draw along.</p>
    </div>
    <form className="teach-form" onSubmit={createLesson}>
      <label htmlFor="teach-topic">What do you want to learn?</label>
      <textarea id="teach-topic" rows="2" value={topic} onChange={e => setTopic(e.target.value)} placeholder="e.g. Binary search, recursion, neural networks, TCP/IP…" disabled={busy} />
      <div className="teach-form-row">
        <label>Teaching style
          <select value={style} onChange={e => setStyle(e.target.value)} disabled={busy}>
            {styles.map(([value, label]) => <option value={value} key={value}>{label}</option>)}
          </select>
        </label>
        <button type="submit" disabled={busy || !topic.trim()}>{busy ? "Preparing lesson…" : "Generate lesson"}</button>
      </div>
    </form>
    {error && <div className="teach-error" role="alert">{error}</div>}
    {displayed && <section className="teach-lesson">
      <div className="teach-lesson-head">
        <div><span className="eyebrow">YOUR LESSON</span><h3>{topic}</h3></div>
        <div className="teach-controls">
          <button type="button" onClick={() => openPaint().catch(e => setError(e.message))}>Open Paint ↗</button>
          {speech === "speaking" && <button type="button" onClick={pause}>Pause voice</button>}
          {speech === "paused" && <button type="button" onClick={resume}>Resume voice</button>}
          <button type="button" onClick={() => speak()} disabled={!lesson}>Read lesson aloud</button>
          <button type="button" className="teach-stop" onClick={stop}>Stop</button>
        </div>
      </div>
      {busy && <p className="teach-generating" role="status">Building the lesson…</p>}
      <article className="teach-content">{displayed}</article>
      <p className="teach-note">Paint is opened as a companion canvas. Follow each numbered drawing instruction yourself; automatic mouse drawing is not enabled in this first version.</p>
    </section>}
    {!displayed && <div className="teach-empty"><span>01 — TOPIC</span><span>02 — BOARD PLAN</span><span>03 — PAINT + VOICE</span><p>Your lesson appears here, with drawing instructions you can follow in Paint.</p></div>}
  </div>;
}
