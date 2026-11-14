const statusEl = document.getElementById("status")!;
document.getElementById("grant")!.addEventListener("click", async () => {
  try {
    const s = await navigator.mediaDevices.getUserMedia({ audio: true });
    s.getTracks().forEach((t) => t.stop());
    statusEl.textContent = "Microphone enabled. You can close this tab.";
    statusEl.className = "ok";
  } catch (e: any) {
    statusEl.textContent = `Could not enable microphone: ${e?.message || e}`;
    statusEl.className = "bad";
  }
});
navigator.permissions?.query({ name: "microphone" as PermissionName }).then((p) => {
  if (p.state === "granted") { statusEl.textContent = "Microphone already enabled."; statusEl.className = "ok"; }
}).catch(() => {});
