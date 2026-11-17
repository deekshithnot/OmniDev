import React, { useEffect, useState } from "react";
import { request } from "./services/api";
import { downloadText } from "./services/download";

export default function Models({ act, refresh, busy }) {
  const [providers, setProviders] = useState([]);
  const [selected, setSelected] = useState("groq");
  const [models, setModels] = useState([]);
  const [routes, setRoutes] = useState([]);
  const [search, setSearch] = useState("");

  async function load() {
    const [availableProviders, pool] = await Promise.all([
      request("/models/providers"),
      request("/models/pool"),
    ]);
    setProviders(availableProviders);
    setRoutes(pool.routes);
    if (!availableProviders.find(item => item.id === selected)?.configured) {
      setSelected(availableProviders.find(item => item.configured && item.id !== "ollama")?.id || selected);
    }
    await refresh();
  }

  useEffect(() => { act(load); }, []);

  const current = providers.find(provider => provider.id === selected);

  useEffect(() => {
    setModels([]);
    if (!current?.configured) return;
    let active = true;
    request(`/models/catalog/${selected}`)
      .then(data => { if (active) setModels(data.models || []); })
      .catch(() => { if (active) setModels([]); });
    return () => { active = false; };
  }, [selected, current?.configured]);

  async function savePool(next) {
    await request("/models/pool", "PUT", { routes: next });
    setRoutes(next);
    await refresh();
  }

  async function discoverAndRegister(providerId) {
    const catalog = await request(`/models/catalog/${providerId}`);
    const chatModels = (catalog.models || []).filter(model => model.capabilities?.includes("chat"));
    const latestPool = await request("/models/pool");
    const existing = new Set(latestPool.routes.map(route => `${route.provider}:${route.model}`));
    const additions = chatModels
      .filter(model => !existing.has(`${providerId}:${model.id}`))
      .map(model => ({ provider: providerId, model: model.id, enabled: true }));
    if (additions.length) {
      await request("/models/pool", "PUT", { routes: [...latestPool.routes, ...additions] });
    }
    setModels(catalog.models || []);
    await load();
    return { discovered: catalog.models?.length || 0, added: additions.length };
  }

  async function saveProvider(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    const providerId = selected;
    await request(`/models/providers/${providerId}`, "PUT", {
      api_key: values.get("key") || "",
      account_id: values.get("account") || "",
    });
    form.reset();
    const result = await discoverAndRegister(providerId);
    return result;
  }

  return (
    <div className="settings-page">
      <span className="eyebrow">BUILT INTO OMNIDEV</span>
      <h2>Models & keys</h2>
      <p>
        Add a provider key once. OmniDev discovers its available chat models and
        adds them to automatic routing. Speech, embedding and other non-chat
        models stay out of the chat router.
      </p>
      <div className="toolbar">
        <button type="button" disabled={busy || !models.length} onClick={() => act(() => downloadText(`omnidev-${selected}-catalog.json`, JSON.stringify(models, null, 2), "application/json"))}>↓ Download model catalog</button>
        <button type="button" disabled={busy || !routes.length} onClick={() => act(() => downloadText("omnidev-model-pool.json", JSON.stringify({ routes }, null, 2), "application/json"))}>↓ Download router configuration</button>
      </div>
      <div className="split connector-forms">
        <div>
          <h3>1. Set up a provider</h3>
          <label>
            Provider
            <select aria-label="Set up provider" value={selected} onChange={event => setSelected(event.target.value)}>
              {providers.map(provider => (
                <option key={provider.id} value={provider.id}>
                  {provider.name}{provider.configured ? " · ready" : ""}
                </option>
              ))}
            </select>
          </label>
          {current && <>
            <p>
              <span className="badge">{current.tier.replaceAll("_", " ")}</span>
              {current.configured ? "Provider configured" : "Provider setup needed"} ·{" "}
              <a href={current.signup_url} target="_blank" rel="noreferrer">Provider website ↗</a>
            </p>
            <form className="form" key={selected} onSubmit={event => {
              event.preventDefault();
              act(() => saveProvider(event));
            }}>
              <label>
                API key
                <input aria-label="Provider API key" name="key" type="password" autoComplete="off" placeholder="Blank keeps a saved key" />
              </label>
              {current.account_id_required && <label>Account ID<input name="account" required /></label>}
              <div className="toolbar">
                <button disabled={busy}>Save key & discover models</button>
                <button disabled={busy} type="button" onClick={() => act(async () => {
                  await request(`/models/providers/${selected}`, "DELETE");
                  await load();
                })}>Remove saved key</button>
              </div>
            </form>
            {current.configured && <button type="button" disabled={busy} onClick={() => act(() => discoverAndRegister(selected))}>↻ Refresh and sync models</button>}
          </>}
          <label>
            Filter discovered models
            <input aria-label="Filter discovered models" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search the provider catalog" />
          </label>
          <p className="muted">{models.filter(model => model.id.toLowerCase().includes(search.toLowerCase())).length} matching models · chat-capable models are automatically routed</p>
          <div className="model-catalog-list">
            {models.filter(model => model.id.toLowerCase().includes(search.toLowerCase())).slice(0, 100).map(model => (
              <div key={model.id} className="model-catalog-row">
                <span>{model.name || model.id}</span>
                <small>{model.capabilities?.includes("chat") ? "Chat" : (model.capabilities || []).join(", ") || "Other"}</small>
              </div>
            ))}
          </div>
        </div>
        <div>
          <h3>2. Automatic model routing</h3>
          <p className="muted">
            Every discovered chat-capable model is added automatically. OmniDev
            tries enabled routes in order, skips models cooling down after errors,
            and falls back before a streamed response starts.
          </p>
          {!routes.length && <p>No models registered yet. Add a provider key to discover models automatically.</p>}
          {routes.map((route, index) => (
            <article key={route.provider + ":" + route.model}>
              <h3>{index + 1}. {route.model}</h3>
              <small>{route.provider}</small>
              <div className="toolbar">
                <label>
                  <input type="checkbox" checked={route.enabled} onChange={event => act(() => savePool(routes.map((item, position) => position === index ? { ...item, enabled: event.target.checked } : item)))} /> Enabled
                </label>
                <button disabled={busy || !index} onClick={() => act(() => {
                  const next = [...routes];
                  [next[index - 1], next[index]] = [next[index], next[index - 1]];
                  return savePool(next);
                })}>Move up</button>
                <button disabled={busy} onClick={() => act(() => savePool(routes.filter((_, position) => position !== index)))}>Remove</button>
              </div>
            </article>
          ))}
          <p className="muted">
            Keys are encrypted in the engine home. A key from your .env remains
            available if you remove a saved key. No gateway server is needed.
          </p>
        </div>
      </div>
    </div>
  );
}
