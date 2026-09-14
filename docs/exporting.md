# Exporting a game that uses Phone Mass Controllers

PMCHost serves controller files with `FileAccess`, which reads **the original bytes**. Godot's
exporter doesn't guarantee those: files it doesn't recognize (`.html`, `.js`, `.css`) are only
packed when they match the preset's *Filters to export non-resource files*, and imported types
(`.png`, `.ogg`, `.ttf`, …) ship as converted resources — the originals are dropped. An export
without the right filters silently loses your controller page (and `/pmc/pmc.js`).

## What the addon does for you

With the editor plugin enabled, its `EditorExportPlugin` packs every served directory **as raw
files** into each export automatically:

- `res://addons/phone_mass_controllers/web` — the `pmc.js` SDK (always; `/pmc/` 404s without it)
- `res://controller` — the `controller_dir` default, when the folder exists
- `controller_dir` on every `PMCHost` node (including subclasses) found in your `.tscn` scenes
- every `res://…` literal passed to `serve_directory("/prefix/", "res://…")` or assigned to
  `controller_dir` in your `.gd` files — which also covers hosts built in code (`PMCHost.new()`)

Watch the export output for `Phone Mass Controllers: packed N controller file(s) from …`.
Directories that don't exist are warned about and skipped; pointing a mount at `res://` itself
is refused (packing the whole project is never what you want) and warned about too.

## Limitations

- Only **string literals** are found. `serve_directory("/x/", some_var)` or `controller_dir`
  computed at runtime can't be seen — keep the literal in a script or use the manual filter below.
- Binary `.scn` scenes aren't scanned; saved `.tscn` scenes are.
- `user://` and absolute-path mounts live outside the pck and need nothing.
- The scan runs at export time and doesn't validate what your server actually serves — it errs on
  the side of packing.

## Manual fallback

If the plugin is disabled or a served directory is dynamic, add the folder to your export
preset's *Filters to export non-resource files*, e.g. `controller/*` (`*` also matches file
names inside subdirectories). Files matching the filter are packed as-is.
