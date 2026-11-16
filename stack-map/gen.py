#!/usr/bin/env python3
"""Render the stack map in two flavours: detailed (IPs, domains) and public (names only).

Usage: python3 gen.py   -> stack-map.html (local only, gitignored), stack-map-public.html (render.sh turns them into PNGs)
"""
from pathlib import Path

HERE = Path(__file__).parent

# (installed software, detail) per chip; detail is hidden in the public version.
GROUPS = {
    "pub": ("Public", [
        ("CSMAK", "csmak.com"), ("Kubo", "kubo.csmak.com"),
        ("Nutria", "nutria.csmak.com"), ("Kebab Oriental", "kebab-oriental.com"),
        ("AJ Gambito", "ajgambitopt.com"), ("Portfolio", "yernau.com"),
        ("Tracker", "tracker.yernau.com"),
    ]),
    "game": ("Games", [
        ("Calagopus Panel", "panel.kubo.csmak.com"), ("Calagopus Wings", "es1.kubo.csmak.com"),
        ("Docker game servers", "*.kubo.csmak.com"),
    ]),
    "per": ("Personal", [
        ("CouchDB LiveSync", "livesync.yernau.com"),
        ("Bulwark Webmail", "webmail.csmak.com"), ("Stalwart Mail", "mail.csmak.com"),
    ]),
    "ts": ("Tailscale only", [
        ("Vaultwarden", "vault"), ("Orbit", "orbit"), ("T3 Code", "andrew-mn56"),
        ("Syncthing", ":22000"), ("OpenSSH", ":22"),
    ]),
}

NODES = {
    "internet": ("Internet", "", ""),
    "vps": ("HAProxy, mc-router", "Edge VPS", "143.20.32.134"),
    "wg_vps": ("WireGuard", "VPS end", "10.66.0.1"),
    "wg_home": ("WireGuard", "Home end", "10.66.0.2"),
    "caddy": ("Caddy", "Reverse proxy", ""),
    "tailnet": ("Tailscale", "Phone, PC", ""),
    "home": ("Home server", "", "192.168.0.111"),
}

CSS = """
:root {
  --bg: #0d1117; --fg: #e6edf3; --muted: #8b949e; --card: #161b22; --border: #30363d;
  --pub: #3fb950; --per: #58a6ff; --game: #f0883e; --ts: #a371f7; --wg: #2dd4bf;
  --r: 8px; --sans: Inter, "Segoe UI", system-ui, sans-serif; --mono: "JetBrains Mono", "DejaVu Sans Mono", monospace;
}
* { box-sizing: border-box; }
body { margin: 0; padding: 24px; width: 776px; background: var(--bg); color: var(--fg); font-family: var(--sans); }
.cols { display: grid; grid-template-columns: 1fr 200px; column-gap: 16px; }
.lane-title { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin-bottom: 8px; text-align: center; }
.node { border: 1px solid var(--border); border-radius: var(--r); padding: 8px 12px; text-align: center; background: var(--card); }
.node b { display: block; font-size: 14px; }
small { display: block; color: var(--muted); font-family: var(--mono); font-size: 11px; }
.line { width: 2px; height: 22px; margin: 0 auto; background: var(--border); }
.line.ts { background: var(--ts); }
.wg { border: 2px dashed var(--wg); border-radius: var(--r); padding: 10px 12px; background: color-mix(in srgb, var(--wg) 8%, transparent); }
.wg h4 { margin: 0 0 8px; color: var(--wg); font-size: 12px; letter-spacing: .06em; text-transform: uppercase; text-align: center; }
.wg .row { display: flex; align-items: center; gap: 10px; }
.wg .row .node { flex: 1; border-color: var(--wg); }
.wg .pipe { flex: 1.2; height: 4px; border-radius: 2px; background: var(--wg); }
.wg-drop { width: 4px; height: 22px; margin: 0 auto; background: var(--wg); }
.host { border: 1px solid var(--border); border-radius: var(--r); padding: 14px 16px 16px; display: grid; grid-template-columns: 1fr 200px; column-gap: 16px; }
.host > .label { grid-column: 1 / span 2; font-size: 12px; color: var(--muted); margin-bottom: 10px; }
.group { border-radius: var(--r); padding: 10px; border: 1px solid; margin-top: 10px; }
.group:first-child { margin-top: 0; }
.group h4 { margin: 0 0 8px; font-size: 12px; letter-spacing: .04em; text-transform: uppercase; }
.chips { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 6px; }
.chip { background: var(--card); border-radius: 6px; padding: 6px 8px; border: 1px solid var(--border); }
.chip b { display: block; font-size: 13px; font-weight: 600; }
.pub { border-color: color-mix(in srgb, var(--pub) 50%, transparent); } .pub h4 { color: var(--pub); }
.per { border-color: color-mix(in srgb, var(--per) 50%, transparent); } .per h4 { color: var(--per); }
.game { border-color: color-mix(in srgb, var(--game) 50%, transparent); } .game h4 { color: var(--game); }
.ts { border-color: color-mix(in srgb, var(--ts) 50%, transparent); } .ts h4 { color: var(--ts); }
.ts .chips { grid-template-columns: 1fr; }
.legend { display: flex; gap: 20px; justify-content: center; margin-top: 14px; font-size: 12px; color: var(--muted); }
.legend i { display: inline-block; width: 18px; height: 4px; border-radius: 2px; vertical-align: middle; margin-right: 6px; }
"""


def render(detailed: bool) -> str:
    def sub(text):
        return f"<small>{text}</small>" if detailed and text else ""

    def node(key, cls="node"):
        name, role, detail = NODES[key]
        role = f"<small>{role}</small>" if role else ""
        return f'<div class="{cls}"><b>{name}</b>{role}{sub(detail)}</div>'

    def group(key):
        title, chips = GROUPS[key]
        role = "<small>Website</small>" if key == "pub" else ""
        items = "".join(f'<div class="chip"><b>{n}</b>{role}{sub(d)}</div>' for n, d in chips)
        return f'<div class="group {key}"><h4>{title}</h4><div class="chips">{items}</div></div>'

    home_name, _, home_detail = NODES["home"]
    home_label = f"{home_name} {home_detail}" if detailed else home_name
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="cols">
  <div>
    <div class="lane-title">Public path</div>
    {node("internet")}
    <div class="line"></div>
    {node("vps")}
    <div class="wg-drop"></div>
    <div class="wg"><h4>WireGuard tunnel</h4>
      <div class="row">{node("wg_vps")}<div class="pipe"></div>{node("wg_home")}</div>
    </div>
    <div class="wg-drop"></div>
  </div>
  <div style="display:flex; flex-direction:column">
    <div class="lane-title">Private path</div>
    {node("tailnet")}
    <div class="line ts" style="flex:1"></div>
  </div>
</div>
<div class="host">
  <div class="label">{home_label}</div>
  <div>
    {node("caddy")}
    <div style="height:10px"></div>
    {group("pub")}{group("game")}{group("per")}
  </div>
  <div>{group("ts")}</div>
</div>
<div class="legend">
  <span><i style="background:var(--wg)"></i>WireGuard</span>
  <span><i style="background:var(--ts)"></i>Tailscale</span>
  <span><i style="background:var(--border)"></i>Internet</span>
</div>
</body></html>"""


(HERE / "stack-map.html").write_text(render(True))
(HERE / "stack-map-public.html").write_text(render(False))
