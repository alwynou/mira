# Mira Minimal Prototype Design QA

- Original direction: `/Users/alwyn/dev/mira/prototypes/mira-minimal/reference/selected-option-2.png`
- Current implementation: `http://localhost:4173/`
- Persistent comparison artifact: `/Users/alwyn/dev/mira/prototypes/mira-minimal/qa-comparison.html`
- Latest annotated viewport: `946 × 998` CSS px, `devicePixelRatio = 1`
- Latest reviewed state: Inbox selected, unassigned conversations visible, no attachment, default authorization, `GPT-5.6 Sol` selected.

## Annotation iteration

The latest user annotations supersede the original source where they explicitly differ:

- Inbox now behaves like a category and reveals conversations that are not assigned to a workspace. Selecting Inbox removes the active workspace treatment and hides workspace conversation children.
- A native-style sidebar control appears in the window toolbar. Collapsing moves the canvas to `x 0`; an unobtrusive canvas control restores the sidebar.
- The composer is shorter and sits close to the bottom edge.
- The former abstract route value now displays the selected model name and offers concrete model choices.

## Focused measurements

- Sidebar expanded: `262 × 998`
- Composer: `x 286`, `y 821`, `636 × 155`
- Composer bottom gap: `22px`
- Collapsed canvas left edge: `0px`
- Inbox unassigned conversation rows: 3

The composer remains centered in the available canvas with a `24px` horizontal safety margin at the annotated viewport width. Its `155px` rendered height replaces the previous `186px` box, and the bottom gap replaces the previous `80px` offset.

## Visual and interaction evidence

- Inbox selection shows `本周计划与待办`, `模型服务配置想法`, and `整理零散产品笔记` directly beneath the category.
- Selecting an Inbox child opens that conversation while Inbox remains active; clicking Inbox again returns to the category landing state.
- No workspace row remains visually active while Inbox is the current category.
- The composer scope and context line both change to Inbox-specific copy in that state.
- Sidebar collapse and restore were exercised at `946 × 998`.
- Model menu options were verified as `GPT-5.6 Sol`, `GPT-5.6 Luna`, and `Qwen3 32B · 本地`; changing the selection updates the visible control.
- Default delivery state was restored to Inbox with `GPT-5.6 Sol` visible.
- The final screenshot was checked in the Codex in-app Browser at the annotated viewport.

## Regression checks

- `npm run build`: passed.
- `npm run test:sites`: 4 tests passed.
- Existing workspace selection, suggestions, composer actions, authorization controls, attachment menu, search, and send behavior remain intact.
- Color remains limited to black, white, neutral grays, and the standard macOS traffic-light colors.

## Follow-up polish

- [P3] Replace the generic cloud outline with a finalized Mira brand mark once the app-icon direction is approved.

final result: passed
