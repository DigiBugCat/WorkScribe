# Obsidian Web Clipper template

`workscribe-template.json` is a template for Obsidian's official Web Clipper.
Import it in the Clipper's settings (Templates → Import). Clips land in
`Clippings/<date> <title>.md` with frontmatter WorkScribe reads:

| Property | WorkScribe uses it as |
| --- | --- |
| `type: clip` | marks the note as a web clip (search kind `clip`) |
| `source` | the clip's URL |
| `site` | the site name shown on results (falls back to the URL's host) |
| `clipped` | when it was clipped |
| `highlights` | highlighted passages (also read from `==highlights==` in the body) |
| `title`, `author`, `published`, `description`, `tags` | shown and searchable |

WorkScribe also recognizes the Clipper's default template (`source` + `created`
+ the `clippings` tag) and any note under `Clippings/`, so existing clips are
indexed without changes.
