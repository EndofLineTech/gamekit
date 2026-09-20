"use strict";
(() => {
  const form = document.querySelector("#filters");
  if (!form) return;
  const search = document.querySelector("#search");
  const backend = document.querySelector("#backend");
  const status = document.querySelector("#status");
  const rows = Array.from(document.querySelectorAll("#matrix tbody tr"));
  const params = new URLSearchParams(window.location.search);
  search.value = params.get("q") || "";
  for (const select of [backend, status]) {
    const value = params.get(select.id);
    if (Array.from(select.options).some(option => option.value === value)) select.value = value;
  }
  function update() {
    const query = search.value.trim().toLowerCase();
    let count = 0;
    for (const row of rows) {
      const states = backend.value === "any"
        ? ["apple", "dxmt", "dxvk", "other"].map(key => row.dataset[key])
        : [row.dataset[backend.value]];
      // With no specific backend, Untested means no evidence for the game,
      // rather than merely one untested renderer on an otherwise tested title.
      const matches = status.value === "all" || (status.value === "tested"
        ? states.some(value => value !== "untested")
        : status.value === "untested" ? states.every(value => value === "untested")
        : states.includes(status.value));
      row.hidden = !(matches && (!query || row.dataset.name.includes(query) || row.dataset.id.includes(query)));
      if (!row.hidden) count++;
    }
    document.querySelector("#result-count").textContent = `Showing ${count} of ${rows.length} games`;
    document.querySelector("#empty").hidden = count !== 0;
    const url = new URL(window.location.href);
    url.search = "";
    if (search.value) url.searchParams.set("q", search.value);
    if (backend.value !== "any") url.searchParams.set("backend", backend.value);
    if (status.value !== "all") url.searchParams.set("status", status.value);
    window.history.replaceState(null, "", url);
  }
  form.addEventListener("submit", event => event.preventDefault());
  form.addEventListener("input", update);
  form.addEventListener("change", update);
  form.addEventListener("reset", () => {
    search.value = ""; backend.value = "any"; status.value = "all";
    window.setTimeout(update, 0);
  });
  update();
})();
