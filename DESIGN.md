# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-06-15
- Primary product surfaces: ARCA Demo web dashboard, ARCA macOS app, ARCA hardware ingest, future iPhone and Watch clients
- Evidence reviewed: `external/omi/desktop/macos/Desktop/Sources/MainWindow/Pages/ConversationsPage.swift`, `external/omi/desktop/macos/Desktop/Sources/MainWindow/Components/ConversationRowView.swift`, `external/omi/desktop/macos/Desktop/Sources/Rewind/Core/TranscriptionStorage.swift`, `external/omi/desktop/macos/Desktop/Sources/Chat/AgentBridge.swift`, `https://github.com/bitjaru/styleseed.git`

## Brand
- Personality: technical, quiet, sovereign, memory-first, hardware-aware
- Trust signals: local-first queues, source provenance, visible sync state, clear device identity, agent attribution
- Avoid: Omi hardware framing, generic AI companion language, decorative gradients, anonymous memory cards, vague cloud magic

## Product goals
- Goals: make ARCA the second brain hub across hardware, Mac, iPhone, Watch, and AI coding/agent sessions
- Non-goals: cloning every Omi feature, hiding source provenance, depending on Omi hardware assumptions
- Success signals: a capture or agent session appears in Conversations with source, compact understanding, transcript, and actionable memory context

## Personas and jobs
- Primary personas: founder-builder using multiple agents, hardware prototyper, operator reviewing decisions across devices
- User jobs: recover what was discussed with each agent, see which tool knew what, inspect compacted understanding, turn recordings and chats into memory
- Key contexts of use: Mac desk work, hardware lab sessions, mobile review, watch capture

## Information architecture
- Primary navigation: Home, Conversations, Chat, Memories, Tasks, Rewind, Apps, Settings
- Core routes/screens: Conversations as the universal capture ledger; Chat as active reasoning; Rewind as raw screen/context history; Memories as durable facts
- Content hierarchy: source badge first, title second, compact understanding third, raw transcript/detail on demand

## Design principles
- Principle 1: Every memory object must show where it came from
- Principle 2: ARCA should expose the connection graph between human, hardware, app, cloud, and agent
- Tradeoffs: prefer dense scannability over marketing polish; keep motion short and functional

## Visual language
- Color: ARCA cinematic surfaces use `#000000`, warm off-white `#ffedd7`, copper/orange `#dc5000`/`#ff7a1a`, and small violet accents; operational surfaces inherit the same tokens at lower intensity
- Typography: cinematic/sales surfaces may use large literal product headlines; operational panels keep compact readable system typography and never use hero-scale text inside tools
- Spacing/layout rhythm: cinematic surfaces are scene-based, with each viewport acting like a distinct frame; operational surfaces use dense lists with clear source badges and generous row tap targets
- Shape/radius/elevation: sales scenes may use 27-43px organic product-frame radii; controls and rows stay at 8-18px unless the surrounding surface is explicitly cinematic
- Motion: sales/companion surfaces use scroll-linked scene progression, pointer parallax, device pulse, signal equalizers, and state-based live capture; operational surfaces use StyleSeed `snap` for hover/controls, `silk` for entrance, and `pulse` only for live indicators; all motion respects reduced motion
- Imagery/iconography: SF Symbols for operational icons; ARCA icon and companion use abstract core/signal glyphs, not Omi product imagery; avoid generic AI orbit/glow unless it is tied to a real state

## Cinematic scene rules
- ARCA sales and first-run screens must be built as a sequence of scenes, not a stack of generic feature cards
- Each scene must have one concrete visual object: ARCA Core, upload line, agent constellation, companion face, or live memory console
- Each scene must expose one interaction: scroll progress, hover/cursor response, live equalizer, import/record state, or source-filter state
- Copy must be specific to the product workflow: recording, uplink, ingest, agent sessions, compact understanding, conversation return
- Avoid generic AI phrases such as "powered by AI", "unlock productivity", "seamless intelligence", or abstract cloud magic
- Video/ffmpeg is allowed only when a real product render, prototype clip, or intentionally authored frame sequence exists; until then CSS/Canvas motion should carry the story

## Components
- Existing components to reuse: `ConversationListView`, `ConversationRowView`, `ConversationDetailView`, `TranscriptionStorage`, `ServerConversation`
- New/changed components: external agent conversation importer, source badges, agent import button, ARCA app icon
- Variants and states: local import loading, import success summary, agent source badges, empty external-source state
- Token/component ownership: keep SwiftUI theme in `OmiColors`/`OmiChrome` until a full ARCA theme rename is scheduled, but map those helpers to ARCA tokens now

## macOS app application
- Home is the living companion surface and may use cinematic ARCA Core motion at reduced density
- Conversations, Memories, Tasks, and Settings remain operational and should not become marketing pages
- The sidebar hardware card opens the ARCA Core sales/first-run page and must feel like a hardware bridge, not an ad
- Companion motion in the app must communicate state: listening, importing, idle, processing, or ready
- macOS surfaces should use ARCA copper/off-white tokens instead of the old purple-first Omi palette

## Accessibility
- Target standard: practical WCAG AA contrast and macOS keyboard/focus compatibility
- Keyboard/focus behavior: import actions must be reachable as buttons with tooltips
- Contrast/readability: source badges must not rely on color alone
- Screen-reader semantics: buttons use explicit labels and help text
- Reduced motion and sensory considerations: use short ease transitions only; do not animate payload text

## Responsive behavior
- Supported breakpoints/devices: macOS desktop window first; future iPhone and Watch clients inherit the same information hierarchy
- Layout adaptations: conversation rows keep source metadata on the secondary line and truncate safely
- Touch/hover differences: hover affordances remain optional; source badges are always visible

## Interaction states
- Loading: import button shows progress without blocking existing conversations
- Empty: Conversations can be empty because no captures or imported sessions exist yet
- Error: import/API errors remain visible in existing conversation error surface
- Success: import summary appears briefly above the list
- Disabled: import button disables while scanning
- Offline/slow network, if applicable: local imported sessions remain visible even when API refresh fails

## Content voice
- Tone: direct, operational, source-aware
- Terminology: ARCA, ARCA Core, agent sessions, compact understanding, source, capture
- Microcopy rules: never say Omi for user-visible ARCA surfaces; name the exact source when available

## Implementation constraints
- Framework/styling system: SwiftUI macOS app, Swift Package Manager, GRDB local SQLite, existing theme helpers
- Design-token constraints: keep current theme helpers for now; do not add a new design-system dependency
- Performance constraints: importer scans newest local session files first and writes through existing local conversation cache
- Compatibility constraints: compile with `xcrun swift build -c debug --package-path Desktop`
- Test/screenshot expectations: build must pass; visual verification should use a named bundle and automation bridge when local signing/runtime is available

## Open questions
- [ ] Which external provider paths should ARCA treat as canonical for OpenClaw, Hermes, and GPT desktop history?
- [ ] Should compact understanding eventually be LLM-generated instead of deterministic first/last-message summaries?
- [ ] Should imported agent sessions sync to ARCA cloud immediately or stay local until explicit opt-in?
