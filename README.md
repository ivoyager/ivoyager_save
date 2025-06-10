# I, Voyager - Save (plugin)

Provides API and GUI for saving and loading games that include procedurally generated node trees. The plugin is very fast because
**only** specified objects and properties are persisted, as specified by class constants.


## Installation

Find more detailed instructions at our [Developers Page](https://www.ivoyager.dev/developers/).

The plugin directory `ivoyager_save` should be added _directly to your addons directory_. You can do this one of two ways:

1. Download and extract the plugin, then add it (in its entirety) to your addons directory, creating an "addons" directory in your project if needed.
2. (Recommended) Add as a git submodule. From your project directory, use git command:  
 `git submodule add https://github.com/ivoyager/ivoyager_save addons/ivoyager_save`  
 This method will allow you to version-control the plugin from within your project rather than moving directories manually. You'll be able to pull updates, checkout any commit, or submit pull requests back to us. This does require some learning to use git submodules. (We use [GitKraken](https://www.gitkraken.com/) to make this easier!)

Then enable "I, Voyager - Save" from the Godot Editor project menu.

## Usage

The [IVSave](https://github.com/ivoyager/ivoyager_save/blob/master/save.gd) singleton has methods to save as (via file dialog), quicksave, autosave, load file (via file dialog), and quickload. These methods can be called directly or via shortcut input actions (if enabled) and an interval timer (for time-based autosaves, if enabled).

The plugin has [GUI Controls](https://github.com/ivoyager/ivoyager_save/tree/master/gui) that you can add to your project. These include two file dialogs (for save and load) and four menu buttons ("Load File", "Quickload", "Save As", and "Quicksave").

[IVTreeSaver](https://github.com/ivoyager/ivoyager_save/blob/master/tree_saver.gd) provides the recursive serialization/deserialization functionality. It can persist properties recursively that are Godot built-in types or one of two kinds of "persist objects":

1. A **"properties-only"** Node can have persist properties but won't be freed and rebuilt on game load.
2. A **"procedural"** Node or RefCounted will be freed and rebuilt on game load.

A Node or RefCounted is identified as a "persist object" by the constant `PERSIST_MODE` with one of the two values:

`const PERSIST_MODE := IVSave.PERSIST_PROPERTIES_ONLY`  
`const PERSIST_MODE := IVSave.PERSIST_PROCEDURAL`

Only listed properties are persisted. Lists are specified as constant arrays in the persist object class:

`const PERSIST_PROPERTIES: Array[StringName] = [&"property1", &"property2", ...]`  
`const PERSIST_PROPERTIES2: Array[StringName] = [&"property3", &"property4", ...] # a subclass can add properties`

Properties can be typed or untyped, although typed is more optimal. Content-typed arrays and dictionaries are especially optimal because data-only containers don't need to be iteratated. Persist objects and containers can be nested within containers at any level of depth or complexity, following rules below. Lists or listed containers can also include WeakRef instances that reference persist objects or null.

During tree build, procedural Nodes are generally instantiated as scripts using `Script.new()`. To instantiate a scene instead, the base Node's GDScript can have one of:

`const SCENE := "<path to .tscn file>"`  
`const SCENE_OVERRIDE := "<path to .tscn file>" # a subclass can override the parent path`

Rules:

1. Persist Nodes must be in the tree.
2. A persist Node's ancestors, up to and including the specified root, must also be persist Nodes.
3. "Properties-only" Nodes cannot have any ancestors that are "procedural".
4. "Properties-only" Nodes must have stable node paths.
5. Inner classes can't be persist objects.
6. Persist RefCounteds can only be "procedural" (not "properties-only").
7. Any listed object (or object nested in a listed container) must be a persist object as defined here.
8. Procedural objects cannot have required args in their `_init()` method.
9. Procedural objects will be destroyed and re-created on load, so any references to these that are not in persist lists must be handled by external code. (Listed properties will be set with new object references.)
10. A persisted array or dictionary cannot be referenced more than once, either directly in lists or indirectly via nesting. This limitation exists for arrays and dictionaries, unlike objects, because GDScript does not allow identification of arrays or dictionaries by reference (see [proposal](https://github.com/godotengine/godot-proposals/issues/874) to fix this). Therefore, a single array or dictionary encountered by IVTreeSaver twice will become two separate arrays or dictionaries on load.
