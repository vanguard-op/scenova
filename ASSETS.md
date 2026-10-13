# ASSETS — Scenova

The build's asset ledger. Slots come from the docs: the branding doc's mark, its forms, style and palette; the screens set's shared-asset declarations; and each screen spec's declared assets. Status is `Done` when the file is on disk, `Pending` until then.

| Slot | File | Family / Variant | Status |
|---|---|---|---|
| A-001 | assets/brand/scenova-mark.svg | Brand mark / master (mark-only, transparent) | Done |
| A-002 | assets/brand/scenova-mark-one-colour.svg | Brand mark / one-colour | Done |
| A-003 | assets/brand/scenova-mark-knockout.svg | Brand mark / knockout | Done |
| A-004 | assets/brand/scenova-lockup-horizontal.svg | Brand mark / horizontal lockup | Done |
| A-005 | assets/brand/scenova-wordmark.svg | Brand mark / wordmark-only | Done |
| A-006 | assets/brand/scenova-app-icon.png | Brand mark / app icon | Done |
| A-007 | assets/brand/scenova-mark-24.svg | Brand mark / 24px | Done |
| A-008 | assets/icons/ | Icon set / outlined + filled | Done |
| A-009 | assets/motion/store-preview.mp4 | Store preview / master | Pending |
| A-010 | assets/motion/first-run-walkthrough.mp4 | First-run walkthrough / master | Pending |
| A-011 | assets/fonts/ | Typography / Lora + Inter (sourced) | Done |

## Brand mark — generation prompt

**Medium**
Image

**Palette**
- ink  #1A1820  (dark #F4F3F7)
- field (app-icon background)  #F7F6F9  (dark #1B1A20)
- plate (over a reading page)  #EEEBFA  (dark #262151)

**Invariants**
An abstract mark: three short horizontal strokes sit in a row at even spacing, and the middle stroke peels upward into a shallow arc, so the line breaks into movement. Lead with the one stroke that leaves the row; the two outer strokes stay short, level, and quiet. One continuous solid tone, flat, crisp edges, uniform stroke weight, no outline, no interior detail, no gradient. Calm, literate, quick, unobtrusive, warm. Centred at 76% of a square 1:1 canvas. Reads in a single tone and stays crisp at 24px. Must never read as a video play button, an open book, or a speech bubble.

**Prompt**
```text
Abstract brand mark: three short horizontal strokes sit in a row at even spacing, and the middle stroke peels upward into a shallow arc so the row breaks into movement. The arc is the single gesture to lead with; the two outer strokes stay short, level, and quiet. One continuous solid tone in ink #1A1820, flat, crisp edges, uniform stroke weight, no outline, no interior detail, no gradient. Calm, literate, and warm: the still shape of a line of reading becoming a moving picture. It must not read as a video play button, an open book, or a speech bubble. Centred, 76% of a square 1:1 canvas, on a transparent background.
```

**Settings**
- Resolution / size: 1024x1024
- Seed / reference: none
- Negative prompt: text, letters, words, watermark, play button, open book, speech bubble, gradient, 3D, drop shadow

**Variants**
| Variant | Delta (by role) | Size |
|---|---|---|
| master (mark-only, transparent) | None (canonical) | 1024 |
| one-colour | None — the mark is already one tone; ink stays #1A1820 | 1024 |
| knockout | ink → #F4F3F7 | 1024 |
| app-icon | background → field #F7F6F9; ink #1A1820 | 1024 |
| mark at 24px | uniform scale, detail stripped | 24 |
| horizontal lockup | add the wordmark "Scenova" set in Lora, mark leading, optically centred on the cap height | 1024x320 |
| wordmark-only | the wordmark "Scenova" set in Lora, no mark | 1024x320 |

**Open questions**
- The app-icon field colour and the plate tint are not declared in the brand doc. Assumed `surface` #F7F6F9 (dark #1B1A20) for the app-icon field, and `primary-100` #EEEBFA (dark #262151) for the plate that sits behind the mark over a reading page.
- The wordmark is set in type (Lora), never generated. The lockup and wordmark-only variants need the Lora font files (A-011).

## Icon set — generation prompt

**Medium**
Image

**Palette**
- default (inactive)  #504C5C  (dark #A7A3B2)
- active  #5C4BC4  (dark #8578E4)
- disabled  #8C8896  (dark #625E6C) at reduced opacity

**Invariants**
A 24px grid, a single uniform 2px stroke, round caps and round joins, soft corners that match the mark's strokes, no interior detail below the stroke, no text. Outlined by default, with a filled form for the active state. One idea per glyph, geometric and even, calm and unobtrusive. Each glyph centred in a square 1:1 canvas on a transparent background, drawn in a single tone.

**Prompt**
```text
A set of nine minimal outlined icons drawn on a 24px grid: one uniform 2px stroke with round caps and round joins, softly rounded corners, no fills in the outlined form, no interior detail below the stroke, no text or letters. The nine glyphs, one idea each: an eye (see it), a play triangle (play), two vertical bars (pause), a circular arrow (replay), a speaker with a small wave (listen), a bookmark (save), a flag (report), a clock with a counter-clockwise arrow (history), and a slider control (settings). Geometric, even, calm and unobtrusive, in a single tone. Each icon centred in a square 1:1 canvas on a transparent background.
```

**Settings**
- Resolution / size: 24x24 (rendered at 1024 for detail, downsampled)
- Seed / reference: none
- Negative prompt: text, letters, words, watermark, gradient, 3D, drop shadow, multiple tones

**Variants**
| Variant | Delta (by role) | Size |
|---|---|---|
| outlined (default) | tone → #504C5C (dark #A7A3B2) | 24 |
| filled (active) | tone → #5C4BC4 (dark #8578E4), shapes filled | 24 |
| disabled | tone → #8C8896 (dark #625E6C) at reduced opacity | 24 |

**Open questions**
- A nine-glyph set rendered in one pass can drift in stroke weight and proportion. If the sheet is inconsistent, each glyph is rendered separately from the same invariants and palette.

## Store preview clip — generation prompt

**Medium**
Video

**Prompt**
```text
A calm, unhurried shot of a reader's phone held in one hand, its screen showing a page of an English novel. One word on the page lifts and a small compact card rises from the lower edge of the screen; inside the card a short moving image plays while the page text stays legible behind it. Reading first, clip second: the page is still the subject, and the card settles and holds. Static camera with a very slow drift, medium shot, soft even daylight from a window camera-left. Warm and gently desaturated grade, paper-and-ink palette: warm off-white #F7F6F9 surfaces, deep ink #1A1820 text, a single violet-indigo accent #5C4BC4 on the card. No cuts, no handheld shake, no readable text, no logos. Seamless loop: the first and last frames match. 8 seconds, 24fps, 9:16.
```

**Settings**
- Resolution / size: 1080x1920 (9:16)
- Motion: 8 seconds at 24fps, seamless loop
- Seed / reference: none
- Negative prompt: readable text, logos, watermarks, cuts, handheld shake, orbit, fast motion

## First-run walkthrough — generation prompt

**Medium**
Video

**Prompt**
```text
A short, silent walkthrough of a phone held in a reader's hand. On a page of a novel, one word is selected with a long press; a small compact card rises from the lower edge of the screen and a short moving image plays inside it; the card settles and the page is left exactly as it was. One continuous action, no cuts. Static camera with a slow drift, medium close-up on the screen, soft even light, warm and gently desaturated grade. Paper-and-ink palette: off-white #F7F6F9 page, ink #1A1820 text, a violet-indigo #5C4BC4 accent on the card. The sequence ends held on the reading page. No readable text, no logos, no audio. 12 seconds, 24fps, 9:16.
```

**Settings**
- Resolution / size: 1080x1920 (9:16)
- Motion: 12 seconds at 24fps, one-shot (no loop), silent
- Seed / reference: none
- Negative prompt: readable text, logos, watermarks, cuts, audio

**Open questions**
- An on-screen UI walkthrough is at the edge of what a video generator renders reliably: the phone UI and any on-screen text will be approximated. If the exact interface is required, capture it from the app itself as a screen recording instead.
