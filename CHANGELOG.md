# Changelog

This file documents changes to [ivoyager_save](https://github.com/ivoyager/ivoyager_save).

File format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

See cloning and downloading instructions [here](https://www.ivoyager.dev/developers/).


## [v0.1] - UNRELEASED

Now release candidate for I, Voyager "beta"!

Under development using Godot 4.5.1.

Breaks older savegame files!

### Fixed
* Procedural nodes are moved to their correct sibling index on load.
* Works now if dialogs are already in tree (rather than procedurally added).
* Some GUI issues from Godot 4.5 update.


## [v0.0.3] - 2025-06-12

Developed using Godot 4.4.1.

Breaks older savegame files!

### Added

* Add Timer functionality for time-based autosaves.
* Add debug functions to test for unfreed procedural objects (likely from RefCounteds with unlisted references).
* More and better doc comments.

## [v0.0.2] - 2025-03-20

Developed using Godot 4.4.

Breaks older savegame files!

### Changed

* Now handles Godot 4.4 typed dictionaries!
* Typed all dictionaries in internal code.
* Changed internal encoding of arrays, dictionaries and objects.
* Removed unnecessary value indexing.
* Removed unmaintained debug functions.
  
## v0.0.1 - 2025-03-07

Developed using Godot 4.3. **The next release will have changes for 4.4!**

Initial alpha release!

This plugin replaces [ivoyager_tree_saver](https://github.com/ivoyager/ivoyager_tree_saver). It has that plugin's functionality plus save/load GUI classes taken out of [ivoyager_core](https://github.com/ivoyager/ivoyager_core).

[v0.1]: https://github.com/ivoyager/ivoyager_save/compare/v0.0.3...HEAD
[v0.0.3]: https://github.com/ivoyager/ivoyager_save/compare/v0.0.2...v0.0.3
[v0.0.2]: https://github.com/ivoyager/ivoyager_save/compare/v0.0.1...v0.0.2
