# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## Mira visual direction

- Preserve an extremely quiet macOS workspace: a pale fixed sidebar, a vast white canvas, one centered prompt, and a low floating composer.
- Use black, white, and neutral gray only, except for the standard macOS traffic-light controls.
- Favor whitespace, typography, and hairline separators over cards, shadows, badges, dashboards, or permanently open inspectors.
- Keep the primary journey focused on selecting a workspace, resuming a conversation, and sending a new message with explicit authorization and route choices.
- Treat Inbox as a peer category to a workspace: it expands to show conversations that have not been assigned to any workspace.
- Keep the sidebar explicitly collapsible from the macOS toolbar and recoverable from the canvas when hidden.
- Keep the floating composer compact and close to the bottom edge; its model control displays the selected model name, not an abstract route label.
