# SessionSwitch Design Lab

10 interactive design directions for SessionSwitch. Pick one.

    cd design-lab && python3 -m http.server 4400

Open http://localhost:4400 — click a card. ←/→ cycles variants, 1–0 jumps,
⌘K opens the quick picker inside any variant.

Engine self-test: `node shared/engine.test.mjs`
