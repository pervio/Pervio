# Vendor marks (vendor-*.imageset)

Vector marks of the model vendors Pervio can route Claude Code / Codex to,
taken from lobe-icons (github.com/lobehub/lobe-icons, MIT, commit 8a1b282 of
2026-10-15; packages/static-svg/icons), fetched 2026-10-16: 智谱 GLM
(zai — the Z.ai Z the person picked, 2026-10-16; black on light, white on dark), DeepSeek (deepseek-color), Kimi (kimi-color — the white K is its
dark rendering; a black-K copy serves the light appearance), MiniMax
(minimax-color), 通义千问 (qwen-color), OpenRouter (the glyph, filled in its
own brand/v2 colourways: #7624F4 on light, #C8FF00 on dark). Each SVG is
stripped to viewBox + shapes; appearance variants are declared in
Contents.json. No tile, no padding, no clipping — a mark is drawn as the vendor
draws it (the favicons used before carried a white square under 智谱's tile,
2026-10-16).

They are each vendor's trademark, used only to identify that vendor in the
engine badge and the provider list of this open-source, non-commercial app.
A vendor that objects: delete its imageset — `VendorMark` falls back to a drawn
monogram automatically.

Added 2026-10-18 for the vendors behind Cursor's models (the engine badge
marks the pick — claude-*, gpt-*, gemini-*, grok-* — beside the model name):
Gemini (gemini-color's star as a flat #3186FF, one rendering for both
appearances; its path data had the arc flags packed lobe-icons style —
`0 01-4.45` — which Xcode's SVG parser reads as nothing, so the flags are
spelled out with spaces, 2026-10-18) and Grok (grok — xAI's mark; black on light, white on dark).
Anthropic and OpenAI need no new file: `VendorMark` points those presets at
the claude-code and codex engine icons the app already carries.
