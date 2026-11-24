# Third-party notices

Pervio's own code is MIT-licensed (see [LICENSE](LICENSE)). It ships with, or
links against, the work of others listed here. Each remains under its own
license; nothing below is relicensed. The license texts themselves are in
[`licenses/`](licenses/).

## Bundled in the app

### Terminal font — MesloLGS NF

`ios/Sources/Resources/MesloLGS-NF-Regular.ttf` is **MesloLGS NF Regular**,
unchanged, from <https://github.com/romkatv/powerlevel10k-media>. It is
**Meslo LG S** by André Berg (a customisation of Apple's Menlo, itself based on
Bitstream Vera and DejaVu), **Apache License, Version 2.0**, patched with glyphs
from **Nerd Fonts** (<https://github.com/ryanoasis/nerd-fonts>).

- Font license and the copyright notice embedded in the file:
  [licenses/MesloLGS-NF.txt](licenses/MesloLGS-NF.txt), full text in
  [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt).
- Nerd Fonts' licensing statement — SIL OFL 1.1 for its patched fonts, MIT for
  its code, and a pointer to the licenses of the individual icon sets:
  [licenses/Nerd-Fonts.txt](licenses/Nerd-Fonts.txt).

It is used only to draw the in-app terminal.

### Engine and vendor marks

The marks that identify an engine or a model vendor in the app
(`ios/Sources/Assets.xcassets/claude-code`, `codex`, `cursor`, `vendor-*`) are
drawn from **lobe-icons** (<https://github.com/lobehub/lobe-icons>, MIT —
[licenses/lobe-icons.txt](licenses/lobe-icons.txt)) — see
`ios/Sources/Assets.xcassets/VENDOR-LOGOS.md` for which file is which. The three
agent badges at the top of the README (`docs/img/readme/agent-*.svg`) carry the
same marks.

They are **trademarks of their respective owners** (Anthropic, OpenAI, Anysphere,
Google, xAI, Zhipu, DeepSeek, Moonshot, MiniMax, Alibaba, OpenRouter). They are
used only to say which engine or vendor a conversation is talking to. Pervio is
an independent project: not affiliated with, sponsored by, or endorsed by any of
them. A vendor that objects can have its mark removed — the app falls back to a
drawn monogram.

## On the website and in the README

These are in `web/` and in the README's pictures (`docs/img/readme/`, composed
from the site's own assets by `scripts/readme-hero.html`); none of them is in
the app.

### Typeface — Wix Madefor

`web/assets/fonts/WixMadeforDisplay-latin.woff2` and `WixMadeforText-latin.woff2`
are the Latin subsets of **Wix Madefor Display** and **Wix Madefor Text**
(<https://github.com/wix/wixmadefor>), unchanged, as Google Fonts serves them.
The site serves them itself, so a visitor's browser asks no third party for a font.

- License: **SIL Open Font License, Version 1.1** —
  [licenses/OFL-WixMadefor.txt](licenses/OFL-WixMadefor.txt).

### Photograph — Mattole beach

`web/assets/photo/mattole-*` are crops of **"Fog bank forming over Mattole
beach"** (King Range National Conservation Area, 19 September 2024) by the
**Bureau of Land Management California**, taken from Wikimedia Commons:
<https://commons.wikimedia.org/wiki/File:Fog_bank_forming_over_Mattole_beach_(54103432351).jpg>.
The same photograph is the ground behind the three phones at the top of the README.

- A work of the United States federal government, in the **public domain**. No
  attribution is required; the site's footer gives it anyway.
- Changes: cropped and resized; the pages draw a darkening gradient over it.
- Its use does not imply that the Bureau of Land Management endorses Pervio.

### Visual system — Hallmark's "Dusk"

The site's palette, its type scale and a few of its CSS recipes (the glass
surface, the light "wells") follow the **Dusk** theme of **Hallmark**
(<https://github.com/Nutlope/hallmark>), a design skill for coding agents. The
values were converted to hex and adapted; the page's layout and content are
Pervio's own.

- License: **MIT** — [licenses/Hallmark.txt](licenses/Hallmark.txt).

## Linked Swift packages

These are not in this repository: Swift Package Manager fetches them when the
app is built, from the list in `ios/project.yml`. A built app contains them, so
anyone who distributes a build has to ship their license texts with it.

| Package | License |
|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT; its bundled bcrypt sources carry BSD and ISC notices |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | MIT; the math fonts it bundles are under the GUST Font License and the SIL OFL 1.1 |
| [BigInt](https://github.com/attaswift/BigInt) | MIT |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 |
| [swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) — the fork of Apple's swift-nio-ssh that Citadel depends on | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections), [swift-atomics](https://github.com/apple/swift-atomics), [swift-system](https://github.com/apple/swift-system) | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log), [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |

## Not bundled

Pervio drives command-line agents that you install and sign in to yourself —
Claude Code, Codex, Cursor — and never redistributes them. Your use of each is
under your own agreement with its vendor. "Claude" and "Claude Code" are
trademarks of Anthropic; "Codex" of OpenAI; "Cursor" of Anysphere.
