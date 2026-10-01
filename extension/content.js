(() => {
  const extractNumber = (text, patterns) => {
    for (const re of patterns) {
      const m = text.match(re);
      if (m) return Number(m[1]);
    }
    return 0;
  };

  function scrape() {
    const root = document.body;
    if (!root) return;

    const text = root.innerText || "";
    const payload = {
      timestamp: new Date().toISOString(),
      source_url: location.href,
      agents_logged_in: extractNumber(text, [/Agents Logged In:\s*(\d+)/i]),
      agents_in_call: extractNumber(text, [/Agents In Calls?:\s*(\d+)/i]),
      agents_waiting: extractNumber(text, [/Agents Waiting:\s*(\d+)/i]),
      agents_paused: extractNumber(text, [/Agents Paused:\s*(\d+)/i]),
      calls_in_queue: extractNumber(text, [/Calls In Queue:\s*(\d+)/i]),
      drop_percent: extractNumber(text, [/DROP PERCENT:\s*([\d.]+)%/i]),
      raw: { title: document.title }
    };

    chrome.runtime.sendMessage({ type: "TELEMETRY", payload });
  }

  const observer = new MutationObserver(() => {
    clearTimeout(window.__cdrTimer);
    window.__cdrTimer = setTimeout(scrape, 250);
  });

  observer.observe(document.body, {subtree: true, childList: true, characterData: true});
  setInterval(scrape, 5000);
  scrape();
})();
