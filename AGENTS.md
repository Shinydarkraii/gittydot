# Contributor instructions

- Keep temporary files in `<repository-name>-temp-chatgpt/` inside this repository, and keep generated output out of commits.
- Preserve Godot `.uid` source identities, upstream attribution and the MIT license. Keep the package version at `0.1.0` unless the user requests a version change.
- Runtime source lives in `addons/gittydot/`; tests live in `tests/`; the runner lives in `tools/`; documentation and license/provenance are at the root.
- If an ignored `LOCAL_SYNC.md` is present, read it before changing the plugin. It identifies the local installed copy that must also be updated. Compare copies first, preserve independent edits, synchronize the requested changes, and inform the user which copies were updated and how they were verified.
- Preserve each copy's packaging differences, documentation links and test paths. Do not copy whole directories blindly, reintroduce the removed combined dock, or include game assets, old addons, caches or generated imports.
- If a linked copy is missing or filesystem permissions prevent updating it, report that limitation and request the required permission; do not claim both copies were updated.
