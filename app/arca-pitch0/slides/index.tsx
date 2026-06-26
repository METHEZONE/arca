import type { SlideDef } from "./types";

import Slide01Title from "./Slide01Title";
import Slide02ColdOpen from "./Slide02ColdOpen";
import Slide03Interruption from "./Slide03Interruption";
import Slide04Field from "./Slide04Field";
import Slide05Numbers from "./Slide05Numbers";
import Slide06Voices from "./Slide06Voices";
import Slide07Bottleneck from "./Slide07Bottleneck";
import Slide08Category from "./Slide08Category";
import Slide09Zone from "./Slide09Zone";
import Slide10Arca from "./Slide10Arca";
import Slide11TwoModes from "./Slide11TwoModes";
import Slide12Pipeline from "./Slide12Pipeline";
import Slide13Demo from "./Slide13Demo";
import Slide14Validation from "./Slide14Validation";
import Slide15Competition from "./Slide15Competition";
import Slide16Moats from "./Slide16Moats";
import Slide17Feasibility from "./Slide17Feasibility";
import Slide18Close from "./Slide18Close";

/**
 * Deck order = SCHOOL script. durationSec = EXACT per-slide Min Voice narration
 * length (tmp/slides-meta.json) → frame-accurate audio↔slide sync. title = 4s
 * silent lead. Sum ≈ 6:47, safely < 14:00. Captions in tmp/captions.srt.
 */
export const slides: SlideDef[] = [
  { id: "title",        title: "Title",                  durationSec: 4,    Component: Slide01Title },
  { id: "cold-open",    title: "Cold open · 90 minutes", durationSec: 25.8, Component: Slide02ColdOpen },
  { id: "interruption", title: "The interruption",       durationSec: 27.5, Component: Slide03Interruption },
  { id: "field",        title: "It wasn't just me",      durationSec: 42.0, Component: Slide04Field },
  { id: "numbers",      title: "57 / 43 · 68 · 64",      durationSec: 23.4, Component: Slide05Numbers },
  { id: "voices",       title: "The voices",             durationSec: 13.4, Component: Slide06Voices },
  { id: "bottleneck",   title: "The bottleneck is you",  durationSec: 36.4, Component: Slide07Bottleneck },
  { id: "category",     title: "The handoff category",   durationSec: 19.1, Component: Slide08Category },
  { id: "the-zone",     title: "THE ZONE",               durationSec: 26.4, Component: Slide09Zone },
  { id: "arca-name",    title: "ARCA = arc+archive+ark", durationSec: 36.0, Component: Slide10Arca },
  { id: "two-modes",    title: "Two modes (core)",       durationSec: 57.1, Component: Slide11TwoModes },
  { id: "pipeline",     title: "4-step pipeline",        durationSec: 57.2, Component: Slide12Pipeline },
  { id: "demo",         title: "Live demo (ARCA app)",   durationSec: 59.6, Component: Slide13Demo },
  { id: "validation",   title: "User validation",        durationSec: 61.6, Component: Slide14Validation },
  { id: "competition",  title: "Competitive matrix",     durationSec: 50.7, Component: Slide15Competition },
  { id: "moats",        title: "Three moats",            durationSec: 37.1, Component: Slide16Moats },
  { id: "feasibility",  title: "Feasibility & market",   durationSec: 53.5, Component: Slide17Feasibility },
  { id: "close",        title: "Close · bookend",        durationSec: 27.0, Component: Slide18Close },
];
