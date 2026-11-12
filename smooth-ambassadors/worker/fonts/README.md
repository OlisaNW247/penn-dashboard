# Fonts for the ambassador pages

Served by the Worker itself at `/a/_fonts/{name}.woff2`, so the pages never
call a third-party host. Basic Latin, Latin-1 and a few punctuation marks only.
Total: about 54 KB.

| File | Family | Source file (in `LowHangingFruitKit/.../Resources/`) | Licence |
|---|---|---|---|
| `familjen-grotesk.woff2` | Familjen Grotesk, variable, weight 400-700 | `FamiljenGrotesk-Variable.ttf` | SIL OFL 1.1 (`FamiljenGrotesk-OFL.txt`) |
| `inter.woff2` | Inter, variable, weight 400-700, optical size fixed at 14 | `Inter.ttf` | SIL OFL 1.1 (`Inter-OFL.txt`) |
| `space-mono.woff2` | Space Mono Regular | `SpaceMono-Regular.ttf` | SIL OFL 1.1 (`SpaceMono-OFL.txt`) |
| `space-mono-bold.woff2` | Space Mono Bold | `SpaceMono-Bold.ttf` | SIL OFL 1.1 (`SpaceMono-OFL.txt`) |

Satoshi and Roobert are not used here: their licences do not cover a website.

Rebuild (fonttools and brotli in a throwaway venv):

```
U="U+0020-007E,U+00A0-00FF,U+2013,U+2014,U+2018,U+2019,U+201C,U+201D,U+2022,U+2026,U+2190,U+2192,U+2197,U+00D7"
fonttools varLib.instancer Inter.ttf opsz=14 wght=400:700 -o inter-lim.ttf
pyftsubset inter-lim.ttf --unicodes="$U" --flavor=woff2 --layout-features='kern,liga,calt,tnum' --no-hinting --desubroutinize --output-file=inter.woff2
pyftsubset FamiljenGrotesk-Variable.ttf   (same options) --output-file=familjen-grotesk.woff2
pyftsubset SpaceMono-Regular.ttf          (same options) --output-file=space-mono.woff2
pyftsubset SpaceMono-Bold.ttf             (same options) --output-file=space-mono-bold.woff2
```
