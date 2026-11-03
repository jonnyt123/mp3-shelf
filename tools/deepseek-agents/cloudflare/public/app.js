// Browser-only dashboard. Token lives only in this tab's JavaScript memory.
(() => {
  "use strict";
  const $ = id => document.getElementById(id);
  const roles = [
    ["mp3-playback", "Playback & Library", "Local media, queues, offline persistence", "PL"],
    ["mp3-sources", "Sources & Downloads", "Spotify metadata and authorized files", "SD"],
    ["mp3-ui", "UI & Accessibility", "SwiftUI, navigation and accessibility", "UI"],
    ["mp3-qa", "QA & Reliability", "Tests, regressions and resilience", "QA"],
    ["mp3-integration", "Integration & Release", "Build configuration and safe integration", "IR"]
  ];
  let token = "";
  let latest = null;
  let busy = false;
  const humanTime = t => t ? new Date(Number(t)).toLocaleString(undefined, {dateStyle:"short",timeStyle:"short"}) : "No activity";
  const roleData = id => (latest?.roleStates || []).find(r => r.role === id);
  const offline = t => !t || Date.now() - Number(t) > 10 * 60 * 1000;
  function notice(message, error = false) {
    const n = $("notification");
    n.textContent = message;
    n.classList.toggle("error", error);
    n.hidden = false;
    clearTimeout(notice.timeout);
    notice.timeout = setTimeout(() => { n.hidden = true; }, 5500);
  }
  async function api(path, payload) {
    if (!/^[a-f0-9]{64}$/i.test(token)) throw Error("Enter your private coordinator token first");
    const r = await fetch(path, {
      method:payload === undefined ? "GET":"POST",
      headers:{authorization:"Bearer "+token, "content-type":"application/json"},
      body:payload === undefined ? undefined : JSON.stringify(payload),
      cache:"no-store", credentials:"omit", redirect:"error"
    });
    if (!r.ok) {
      if (r.status === 401) throw Error("Invalid token. Check your Cloudflare coordinator secret.");
      throw Error("Coordinator request failed: HTTP " + r.status);
    }
    return r.json();
  }
  function stateClass(s) { return ["queued","done","blocked","leased"].includes(s) ? s : "offline"; }
  function render(data) {
    latest = data;
    $("state-value").textContent = data.paused ? "Paused" : "Running";
    $("state-detail").textContent = data.paused ? "No new jobs will start" : "Mac can claim queued jobs";
    const mac = data.mac || {};
    const stale = offline(mac.lastSeen);
    $("runner-value").textContent = stale ? "Offline" : mac.stage === "running" ? "Working" : "Connected";
    $("runner-detail").textContent = mac.lastSeen ? "Last seen " + humanTime(mac.lastSeen) : "Awaiting first Mac heartbeat";
    const counts = data.counts || {};
    $("done-value").textContent = String(counts.done || 0);
    $("waiting-value").textContent = (counts.queued || 0) + " / " + (counts.blocked || 0);
    $("control-message").textContent = data.paused ? "Agent execution is paused. Queue data is preserved." :
      (stale ? "Coordinator resumed, but your Mac has not checked in recently." : "Mac is connected; agents run sequentially within your DeepSeek budget.");
    $("pause").disabled = busy || data.paused;
    $("resume").disabled = busy || !data.paused;
    $("seed").disabled = busy || (data.roleStates?.length || 0) >= 5;
    $("updated-time").textContent = "Updated " + new Date().toLocaleTimeString();
    $("agents").replaceChildren();
    for(const [id,name,desc,symbol] of roles) {
      const j = roleData(id);
      const state = j?.state || "uninitialized";
      const card = document.createElement("article");
      card.className = "agent card";
      const symbolEl = document.createElement("span");
      symbolEl.className = "agent-symbol";
      symbolEl.textContent = symbol;
      const content = document.createElement("div");
      content.className = "agent-content";
      const title = document.createElement("h3"); title.className = "agent-name"; title.textContent = name;
      const subtitle = document.createElement("p"); subtitle.className = "agent-info";
      subtitle.textContent = desc + (j ? " · Cycle " + (Number(j.cycle)+1) : "");
      content.append(title,subtitle);
      const actions = document.createElement("div"); actions.className = "agent-actions";
      const tag = document.createElement("span"); tag.className = "state-tag " + stateClass(state);
      tag.textContent = state === "leased" ? "Working" : state === "queued" ? "Queued" :
        state === "done" ? "Complete" : state === "blocked" ? "Blocked" : "Inactive";
      actions.append(tag);
      if(state === "blocked") {
        const retry = document.createElement("button"); retry.className = "small-button";
        retry.type = "button"; retry.textContent = "Retry";
        retry.setAttribute("aria-label", "Retry blocked job for " + name);
        retry.addEventListener("click", () => action("/v1/retry",{jobId:j.id},"Job requeued"));
        actions.append(retry);
      }
      card.append(symbolEl, content, actions);
      $("agents").append(card);
    }
    const activity = $("activity");
    activity.replaceChildren();
    if (!data.recent?.length) {
      const p = document.createElement("p"); p.className = "empty"; p.textContent = "No development activity yet. Initialize the queue to begin.";
      activity.append(p);
    } else {
      for(const j of data.recent) {
        const row = document.createElement("div");row.className = "activity-row";row.setAttribute("role","listitem");
        const dot = document.createElement("span");dot.className = "activity-dot " + stateClass(j.state);
        const content = document.createElement("div");content.className = "activity-main";
        const label = document.createElement("strong");
        label.textContent = (roles.find(x=>x[0]===j.role)?.[1] || j.role) + " · " + j.state;
        const desc = document.createElement("small");desc.textContent = "Cycle " + (Number(j.cycle)+1) + " · Attempt " + j.attempts +
          (j.commit_sha ? " · " + j.commit_sha.slice(0,9) : "");
        content.append(label,desc);
        const time = document.createElement("time");time.className = "activity-time";
        time.textContent = humanTime(j.updated_at);
        row.append(dot,content,time);activity.append(row);
      }
    }
  }
  async function refresh() {
    if (!token || busy) return;
    try {
      const data = await api("/v1/status");
      render(data);
      $("connection-dot").classList.add("connected");
      $("connection-label").textContent = "Coordinator connected";
    } catch(e) {
      $("connection-dot").classList.remove("connected");
      $("connection-label").textContent = "Connection lost";
      notice(e.message,true);
    }
  }
  async function action(path,data,label) {
    if(busy) return;
    busy = true;
    $("pause").disabled = $("resume").disabled = $("seed").disabled = true;
    try {
      await api(path,data);
      notice(label);
    } catch(e) { notice(e.message,true); }
    finally { busy = false; await refresh(); }
  }
  $("login-form").addEventListener("submit", async e => {
    e.preventDefault();
    const proposed = $("token").value.trim();
    if(!/^[a-f0-9]{64}$/i.test(proposed)) return notice("Token must be a 64-character hexadecimal value",true);
    token = proposed;
    $("token").value = "";
    try {
      const data = await api("/v1/status");
      $("auth-panel").hidden = true;
      $("console").hidden = false;
      render(data);
      $("connection-dot").classList.add("connected");
      $("connection-label").textContent = "Coordinator connected";
    } catch(e) {
      token = ""; notice(e.message,true);
    }
  });
  $("refresh").addEventListener("click",refresh);
  $("lock").addEventListener("click",()=>{
    token = "";latest = null;
    $("console").hidden = true;$("auth-panel").hidden = false;
    $("connection-dot").classList.remove("connected");
    $("connection-label").textContent = "Not connected";
    $("token").focus();
  });
  $("seed").addEventListener("click",()=>action("/v1/seed",{},"Five agents initialized"));
  $("pause").addEventListener("click",()=>action("/v1/pause",{paused:true},"New agent sessions paused"));
  $("resume").addEventListener("click",()=>action("/v1/pause",{paused:false},"Agent queue resumed"));
  document.addEventListener("visibilitychange",()=>{if(!document.hidden) refresh();});
  setInterval(()=>{if(!document.hidden) refresh();},20000);
})();
