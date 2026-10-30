# Icon artwork

All choices use existing artwork, not generated font variants. Source files were fetched on 2026-10-30.

| Choice | Original source | License |
|---|---|---|
| Official | [Pi website logo](https://pi.dev/logo-auto.svg), linked by the [official repository](https://github.com/earendil-works/pi) | Pi brand artwork |
| Lucide | [pi.svg](https://github.com/lucide-icons/lucide/blob/main/icons/pi.svg) | ISC; see `licenses/lucide.txt` |
| Phosphor | [pi.svg](https://github.com/phosphor-icons/core/blob/main/assets/regular/pi.svg) | MIT; see `licenses/phosphor.txt` |
| Phosphor Bold | [pi-bold.svg](https://github.com/phosphor-icons/core/blob/main/assets/bold/pi-bold.svg) | MIT; see `licenses/phosphor.txt` |
| Material | [pi.svg](https://github.com/Templarian/MaterialDesign/blob/master/svg/pi.svg) | Apache 2.0; see `licenses/material-design-icons.txt` and `licenses/apache-2.0.txt` |

`pi-official.svg` is preserved unchanged. Its polygon coordinates and sRGB colors are rendered directly by Core Graphics, cropping surrounding whitespace and scaling only. Its status dot uses the logo's blue for visibility on light and dark menu bars. Use of Pi artwork does not imply endorsement.

`icons/*.svg` are the library originals. Their corresponding transparent 128×128 PNGs were rasterized directly with Chromium Canvas, preserving view boxes, geometry and stroke widths. `build.sh` bundles PNGs and license notices; the app uses template tinting for these monochrome icons. Normal builds and runtime need no browser, downloads or additional image libraries.
