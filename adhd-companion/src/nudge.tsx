import React, { useEffect, useState } from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

type Priority = { id: number; text: string; status: string };

function NudgeApp() {
  const params = new URLSearchParams(window.location.search);
  const level = params.get("level") ?? "L2";
  const [priorities, setPriorities] = useState<Priority[]>([]);
  const [message, setMessage] = useState("Still with your list?");

  useEffect(() => {
    void invoke<{ priorities: Priority[]; message: string }>("get_nudge_view_model").then(
      (vm) => {
        setPriorities(vm.priorities ?? []);
        setMessage(vm.message ?? message);
      },
    );
  }, []);

  async function ack(reason: string) {
    await invoke("acknowledge_nudge", { reason });
  }

  return (
    <div className="app-shell" style={{ padding: "1.25rem" }}>
      <h1 className="brand" style={{ fontSize: "1.6rem" }}>
        {level === "L3" ? "Take a breath" : "Quick check-in"}
      </h1>
      <p className="tagline">{message}</p>
      <ul className="list">
        {priorities
          .filter((p) => p.status === "active")
          .map((p) => (
            <li key={p.id}>{p.text}</li>
          ))}
      </ul>
      <div className="row">
        <button className="primary" onClick={() => void ack("doing_it")}>
          Doing it
        </button>
        <button className="secondary" onClick={() => void ack("snooze")}>
          Snooze 20m
        </button>
        <button className="secondary" onClick={() => void ack("resolve")}>
          Thanks — dismiss
        </button>
        <button className="danger" onClick={() => void ack("overwhelm")}>
          Overwhelm
        </button>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <NudgeApp />
  </React.StrictMode>,
);
