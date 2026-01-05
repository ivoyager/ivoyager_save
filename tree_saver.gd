# tree_saver.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2019-2026 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
class_name IVTreeSaver
extends RefCounted

## Provides functions to: 1) Generate a compact game-save data structure from
## specified (and [u]only[/u] specified) objects and properties in a scene tree.
## 2) Set properties and rebuild procedural parts of the scene tree on game load.
##
## This system can persist properties recursively that are Godot built-in types
## or one of two kinds of "persist objects":[br][br]
##    
## 1. A [b]"properties-only"[/b] [Node] can have persist data but won't be freed and
##    rebuilt on game load.[br]
## 2. A [b]"procedural"[/b] [Node] or [RefCounted] will be freed and rebuilt on game
##    load.[br][br]
##
## A Node or RefCounted is identified as a "persist object" by the constant
## [code]PERSIST_MODE[/code] with one of the two values:[br][br]
##
## [code]const PERSIST_MODE := IVSave.PERSIST_PROPERTIES_ONLY[/code][br]
## [code]const PERSIST_MODE := IVSave.PERSIST_PROCEDURAL[/code][br][br]
##
## Only listed properties are persisted. Lists are specified as constant
## arrays in the persist object class:[br][br]
##
## [code]const PERSIST_PROPERTIES: Array[StringName] = [&"property1", &"property2", ...][/code][br]
## [code]const PERSIST_PROPERTIES2: Array[StringName] = [&"property3", &"property4", ...][/code]
## [br][br]
##
## List names can be modified or appended in [member IVSaveUtils.persist_property_lists].
## Multiple lists are supported so that subclasses can add persist properties to
## parent classes.[br][br]
##
## Properties can be typed or untyped, although typed is more optimal. Content-
## typed arrays and dictionaries are especially optimal because data-only
## containers don't need to be iteratated. Persist objects and containers can be
## nested within containers at any level of depth or complexity, following rules
## below. Lists or listed containers can also include WeakRef instances that
## reference persist objects or null.[br][br]
##
## During tree build, procedural [Node]s are generally instantiated as scripts using
## [code]Script.new()[/code]. To instantiate a scene instead, the base [Node]'s
## GDScript can have one of:[br][br]
##
## [code]const SCENE := "<path to .tscn file>"[/code][br]
## [code]const SCENE_OVERRIDE := "<path to .tscn file>" # a subclass can override the parent path
## [/code][br]
##
## Rules:[br][br]
##
## 1. Persist [Node]s must be in the tree.[br]
## 2. A persist [Node]'s ancestors, up to and including [code]save_root[/code],
##    must also be persist [Node]s.[br]
## 3. "Properties-only" [Node]s cannot have any ancestors that are "procedural".[br]
## 4. "Properties-only" [Node]s must have stable node paths.[br]
## 5. Inner classes can't be persist objects.[br]
## 6. Persist [RefCounted]s can only be "procedural" (not "properties-only").[br]
## 7. Any listed object (or object nested in a listed container) must be a
##    "persist object" as defined here.[br]
## 8. Procedural objects cannot have required args in their [code]_init()[/code]
##    method.[br]
## 9. Procedural objects will be destroyed and re-created on load, so any
##    references to these that are not in persist lists must be handled by
##    external code. (Listed properties will be set with new object references.)[br]
## 10. A persisted array or dictionary cannot be referenced more than once,
##    either directly in lists or indirectly via nesting. This limitation exists
##    for arrays and dictionaries, unlike objects, because GDScript
##    does not allow identification of arrays or dictionaries by reference
##    (see [url=https://github.com/godotengine/godot-proposals/issues/874]
##    proposal[/url] to fix this). Therefore, a single array or dictionary
##    encountered by [IVTreeSaver] twice will become two separate arrays or
##    dictionaries on load.[br][br]
##
## Forward compatability of game saves:[br][br]
##
## IVTreeSaver provides some limited flexibility for updating classes while
## maintaining compatibility with older game save files. Specifically, an
## updated class can have additional persist properties that did not exist in
## the previous game save version. However, all properties in the save file must
## still exist in the updated class and be listed in the exact same order.
## I.e., the persist lists can grow, but previous content can't change.
## If you persist the game version, then you can (in theory) add code to handle
## the transition from old to new class properties.

const DPRINT := false # set true for debug print

const PROHIBITED_TYPES: Array[int] = [TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]


# localized
var _persist_property_lists := IVSaveUtils.persist_property_lists

# gamesave file contents
var _gamesave_n_objects := 0
var _gamesave_serialized_nodes: Array[Array] = []
var _gamesave_serialized_refs: Array[Array] = []
var _gamesave_script_paths: Array[String] = []

# save processing
var _nonprocedural_path_root: Node
var _object_ids: Dictionary[Object, int] = {} # indexed by objects
var _script_ids: Dictionary[String, int] = {} # indexed by script paths

# load processing
var _is_detached: bool
var _objects: Array[Object] = [] # indexed by object_id
var _scripts: Array[Script] = [] # indexed by script_id


## Encodes the tree as a data array suitable for file storage, persisting only
## properties listed in object constant lists defined in
## [member IVSaveUtils.persist_property_lists]. [param save_root] must
## be a persist node. It may or may not be procedural (this will determine
## which 'build...' method to call later).
func get_gamesave(save_root: Node) -> Array:
	_nonprocedural_path_root = save_root
	assert(!DPRINT or _dprint("* Registering tree for gamesave *"))
	_index_tree(save_root)
	assert(!DPRINT or _dprint("* Serializing tree for gamesave *"))
	_serialize_tree(save_root)
	var gamesave := [
		_gamesave_n_objects,
		_gamesave_serialized_nodes,
		_gamesave_serialized_refs,
		_gamesave_script_paths,
		]
	print("Persist objects saved: ", _gamesave_n_objects, "; nodes in tree: ",
			save_root.get_tree().get_node_count())
	_reset()
	return gamesave


## Frees all 'procedural' [Node] and [RefCounted] instances starting from
## [param root_node] (which may or may not be procedural). This method
## first nulls all references to objects for all properties that are listed,
## then frees the base procedural nodes.[br][br]
##
## WARNING: This method cannot remove references to objects for properties that
## are not listed in object constants defined in [member IVSaveUtils.persist_property_lists]. 
## Any such references must be removed by some other code.[br][br]
##
## Call this method before [method build_attached_tree] or
## [method build_detached_tree] if there is an existing tree that needs to be
## removed. It is recommended to delay a few frames (we delay 6) before
## building the new tree. Otherwise, freeing procedural objects are still alive
## and may respond to signals during the tree build.[br][br]
##
## You can also call this method before quit or exit to remove circular
## references to procedural objects.
#func free_procedural_objects_recursive(root_node: Node) -> void:
	#IVSaveUtils.free_procedural_objects_recursive(root_node)


## Rebuilds the tree from [param gamesave] data attached to an existing scene tree.
## Call this method if [param save_root] specified in [method get_gamesave] was a
## non-procedural node (using the same [param save_root] supplied in that method).
func build_attached_tree(gamesave: Array, save_root: Node) -> void:
	const PERSIST_PROPERTIES_ONLY := IVSaveUtils.PersistMode.PERSIST_PROPERTIES_ONLY
	assert(save_root)
	assert(type_convert(save_root.get(&"PERSIST_MODE"), TYPE_INT) == PERSIST_PROPERTIES_ONLY,
			"'save_root' must have const PERSIST_MODE = PERSIST_PROPERTIES_ONLY")
	_is_detached = false
	_build_tree(gamesave, save_root)


## Rebuilds the tree from [param gamesave] data in a detatched state. Call this
## method if [param save_root] specified in [method get_gamesave] was a
## procedural node. The method will return the new, procedurally instantiated
## [param save_root].
## @experimental: Not tested.
func build_detached_tree(gamesave: Array) -> Node:
	_is_detached = true
	return _build_tree(gamesave)


func _build_tree(gamesave: Array, save_root: Node = null) -> Node:
	_gamesave_n_objects = gamesave[0]
	_gamesave_serialized_nodes = gamesave[1]
	_gamesave_serialized_refs = gamesave[2]
	_gamesave_script_paths = gamesave[3]
	_load_scripts()
	_locate_or_instantiate_objects(save_root) # null ok if all procedural
	_deserialize_all_object_data()
	_build_procedural_tree()
	var detatched_root: Node
	if _is_detached:
		detatched_root = _objects[0]
	print("Persist objects loaded: ", _gamesave_n_objects)
	_reset()
	return detatched_root


func _reset() -> void:
	_gamesave_n_objects = 0
	_gamesave_serialized_nodes = []
	_gamesave_serialized_refs = []
	_gamesave_script_paths = []
	_nonprocedural_path_root = null
	_object_ids.clear()
	_script_ids.clear()
	_objects.clear()
	_scripts.clear()


# Procedural save

func _index_tree(node: Node) -> void:
	# Make an object_id for all persist nodes by indexing in _object_ids.
	_object_ids[node] = _gamesave_n_objects
	_gamesave_n_objects += 1
	for child in node.get_children():
		if child.get(&"PERSIST_MODE"): # not null nor 0
			_index_tree(child)


func _serialize_tree(node: Node) -> void:
	_serialize_node(node)
	for child in node.get_children():
		if child.get(&"PERSIST_MODE"): # not null nor 0
			_serialize_tree(child)


# Procedural load

func _load_scripts() -> void:
	for script_path in _gamesave_script_paths:
		var script: Script = load(script_path)
		_scripts.append(script) # indexed by script_id


func _locate_or_instantiate_objects(save_root: Node) -> void:
	# Instantiates procecural objects (Node and RefCounted) without data.
	# Indexes root and all persist objects (procedural and non-procedural).
	# 'save_root' can be null if all nodes are procedural.
	assert(!DPRINT or _dprint("* Registering(/Instancing) Objects for Load *"))
	_objects.resize(_gamesave_n_objects)
	for serialized_node in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		var script_id: int = serialized_node[1]
		# Assert user called the right build function
		assert(object_id > 0 or !_is_detached or script_id > -1,
				"Call to 'build_detached...()' but the root node is non-procedural")
		assert(object_id > 0 or _is_detached or script_id == -1,
				"Call to 'build_attached...()' but the root node is procedural")
		var node: Node
		if script_id == -1: # non-procedural node; find it
			var node_path: NodePath = serialized_node[2] # relative
			node = save_root.get_node(node_path)
			assert(!DPRINT or _dprint(object_id, node, node.name))
		else: # this is a procedural node
			var script: Script = _scripts[script_id]
			node = IVSaveUtils.make_object_or_scene(script)
			assert(!DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
		assert(node)
		_objects[object_id] = node
	for serialized_ref in _gamesave_serialized_refs:
		var object_id: int = serialized_ref[0]
		var script_id: int = serialized_ref[1]
		var script: Script = _scripts[script_id]
		@warning_ignore("unsafe_method_access")
		var ref: RefCounted = script.new()
		assert(ref)
		_objects[object_id] = ref
		assert(!DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))


func _deserialize_all_object_data() -> void:
	assert(!DPRINT or _dprint("* Deserializing Objects for Load *"))
	for serialized_node in _gamesave_serialized_nodes:
		_deserialize_object_data(serialized_node, true)
	for serialized_ref in _gamesave_serialized_refs:
		_deserialize_object_data(serialized_ref, false)


func _build_procedural_tree() -> void:
	const PERSIST_PROCEDURAL := IVSaveUtils.PersistMode.PERSIST_PROCEDURAL
	for serialized_node in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		if object_id == 0: # 'save_root' has no parent in the save
			continue
		var node: Node = _objects[object_id]
		if node[&"PERSIST_MODE"] == PERSIST_PROCEDURAL:
			var parent_id: int = serialized_node[2]
			var sibling_index: int = serialized_node[3]
			var parent: Node = _objects[parent_id]
			sibling_index = mini(sibling_index, parent.get_child_count())
			parent.add_child(node)
			parent.move_child(node, sibling_index)


# Serialize/deserialize functions

func _serialize_node(node: Node) -> void:
	const PERSIST_PROCEDURAL := IVSaveUtils.PersistMode.PERSIST_PROCEDURAL
	var serialized_node := []
	var object_id: int = _object_ids[node]
	serialized_node.append(object_id) # index 0
	var script_id := -1
	var is_procedural: bool = node[&"PERSIST_MODE"] == PERSIST_PROCEDURAL
	if is_procedural:
		var script: Script = node.get_script()
		script_id = _get_script_id(script)
		assert(!DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
	else:
		assert(!DPRINT or _dprint(object_id, node, node.name))
	serialized_node.append(script_id) # index 1
	# index 2 will be node path or parent_id or -1
	# index 3 will be child index or -1
	if !is_procedural: # "properties-only"
		var node_path := _nonprocedural_path_root.get_path_to(node)
		serialized_node.append(node_path) # index 2
		serialized_node.append(node.get_index()) # index 3
	elif object_id > 0: # procedural with parent in the tree
		var parent := node.get_parent()
		var parent_id: int = _object_ids[parent]
		serialized_node.append(parent_id) # index 2
		serialized_node.append(node.get_index()) # index 3
	else: # detatched procedural root node
		serialized_node.append(-1) # index 2
		serialized_node.append(-1) # index 3
	_serialize_object_data(node, serialized_node)
	_gamesave_serialized_nodes.append(serialized_node)


func _index_and_serialize_ref(ref: RefCounted) -> int:
	const PERSIST_PROCEDURAL := IVSaveUtils.PersistMode.PERSIST_PROCEDURAL
	assert(ref[&"PERSIST_MODE"] == PERSIST_PROCEDURAL, "RefCounted must be PERSIST_PROCEDURAL")
	var object_id := _gamesave_n_objects
	_gamesave_n_objects += 1
	_object_ids[ref] = object_id
	var serialized_ref := []
	serialized_ref.append(object_id) # index 0
	var script: Script = ref.get_script()
	var script_id := _get_script_id(script)
	assert(!DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))
	serialized_ref.append(script_id) # index 1
	_serialize_object_data(ref, serialized_ref)
	_gamesave_serialized_refs.append(serialized_ref)
	return object_id


func _get_script_id(script: Script) -> int:
	var script_path := script.resource_path
	assert(script_path)
	var script_id: int = _script_ids.get(script_path, -1)
	if script_id == -1:
		script_id = _gamesave_script_paths.size()
		_gamesave_script_paths.append(script_path)
		_script_ids[script_path] = script_id
	return script_id


func _serialize_object_data(object: Object, serialized_object: Array) -> void:
	assert(object is Node or object is RefCounted)
	# serialized_object already has 4 elements (if Node) or 2 (if RefCounted).
	# We now append the size of each persist array followed by data.
	for properties_array in _persist_property_lists:
		var properties: Array[StringName]
		var n_properties: int
		if properties_array in object:
			properties = object.get(properties_array)
			n_properties = properties.size()
		else:
			n_properties = 0
		serialized_object.append(n_properties)
		for property in properties:
			assert(property in object, "Specified persist property '%s' is not in object" % property)
			var value: Variant = object.get(property)
			serialized_object.append(_get_encoded_value(value))


func _deserialize_object_data(serialized_object: Array, is_node: bool) -> void:
	# The order of persist properties must be exactly the same from game save to
	# game load. However, it's ok if a version-updated class has a longer list.
	var index := 4 if is_node else 2
	var object_id: int = serialized_object[0]
	var object: Object = _objects[object_id]
	for properties_array in _persist_property_lists:
		var n_properties: int = serialized_object[index]
		index += 1
		if n_properties == 0:
			continue
		var properties: Array = object.get(properties_array)
		var property_index := 0
		while property_index < n_properties:
			var property: StringName = properties[property_index]
			var encoded_value: Variant = serialized_object[index]
			index += 1
			assert(property in object, "Specified persist property '%s' is not in object" % property)
			object.set(property, _get_decoded_value(encoded_value))
			property_index += 1


func _get_encoded_value(value: Variant) -> Variant:
	# Returns any type other than Object or prohibited types. Encoded String
	# type is overloaded to represent either a String or an Object, where
	# the 1st character is an identifier:
	#
	# "'" - Everything after ' is an encoded string (encoded here).
	# "*" - Object. Digits after * encode an object id. See _get_encoded_object().
	# "!" - WeakRef to an object. Digits after ! encode an object id. See _get_encoded_object().
	#
	# Note: "" is a reserved key used for dictionary type encoding that can't
	# collide with anything above.	
	var type := typeof(value)
	if type == TYPE_STRING:
		return "'" + value
	if type == TYPE_OBJECT:
		var object: Object = value
		return _get_encoded_object(object) # always a String begining with "*" or "!"
	if type == TYPE_ARRAY:
		var array: Array = value
		return _get_encoded_array(array) # array
	if type == TYPE_DICTIONARY:
		var dict: Dictionary = value
		return _get_encoded_dict(dict) # dict
	assert(!PROHIBITED_TYPES.has(type), "Can't persist type %s" % type)
	return value # all other built-in types encoded as is


func _get_decoded_value(encoded_value: Variant) -> Variant:
	# Inverse encoding above.
	var encoded_type := typeof(encoded_value)
	if encoded_type == TYPE_STRING: # encoded String or Object
		var encoded_string: String = encoded_value
		if encoded_string[0] == "'":
			return encoded_string.substr(1)
		else:
			return _get_decoded_object(encoded_string)
	if encoded_type == TYPE_ARRAY:
		var encoded_array: Array = encoded_value
		return _get_decoded_array(encoded_array)
	if encoded_type == TYPE_DICTIONARY:
		var encoded_dict: Dictionary = encoded_value
		return _get_decoded_dict(encoded_dict)
	return encoded_value


func _get_encoded_array(array: Array) -> Array:
	
	const UNSAFE_TYPES: Array[int] = [TYPE_NIL, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT]
	
	var array_type := array.get_typed_builtin()
	if !UNSAFE_TYPES.has(array_type):
		assert(!PROHIBITED_TYPES.has(array_type), "Can't persist type %s" % array_type)
		return array.duplicate() # duplicates array type!
	
	# All others will be encoded as an untyped array with typing info
	# appended. Type could be an object super-class (e.g., Node) in which case
	# script_id will be -1.
	
	var array_class_name := &""
	var array_script_id := -1
	if array_type == TYPE_OBJECT:
		array_class_name = array.get_typed_class_name()
		var array_script: Script = array.get_typed_script()
		if array_script:
			array_script_id = _get_script_id(array_script)
	
	var size := array.size()
	var encoded_array := []
	encoded_array.resize(size + 3)
	encoded_array[-1] = array_type
	encoded_array[-2] = array_class_name
	encoded_array[-3] = array_script_id
	
	var index := 0
	while index < size:
		encoded_array[index] = _get_encoded_value(array[index])
		index += 1
	return encoded_array


func _get_decoded_array(encoded_array: Array) -> Array:
	# Inverse encoding above. Return type matches the original unencoded array.
	if encoded_array.is_typed():
		return encoded_array.duplicate()
	
	var array_type: int = encoded_array[-1]
	var array_class_name: StringName = encoded_array[-2]
	var array_script_id: int = encoded_array[-3]
	var array_script := _scripts[array_script_id] if array_script_id != -1 else null
	
	var size := encoded_array.size() - 3
	var array := Array([], array_type, array_class_name, array_script)
	array.resize(size)
	var index := 0
	while index < size:
		array[index] = _get_decoded_value(encoded_array[index])
		index += 1
	return array


func _get_encoded_dict(dict: Dictionary) -> Dictionary:
	 
	const UNSAFE_TYPES: Array[int] = [TYPE_NIL, TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT]
	const TYPE_KEY := "" # not a possible return of _get_encoded_value()
	
	var key_type := dict.get_typed_key_builtin()
	var value_type := dict.get_typed_value_builtin()
	if !UNSAFE_TYPES.has(key_type) and !UNSAFE_TYPES.has(value_type):
		assert(!PROHIBITED_TYPES.has(key_type), "Can't persist type %s" % key_type)
		assert(!PROHIBITED_TYPES.has(value_type), "Can't persist type %s" % value_type)
		return dict.duplicate() # duplicates dict type!
	
	# All others will be encoded as a fully untyped dict with typing stored at
	# TYPE_KEY (safe due to key encoding). Key or value type could be an
	# object super-class (e.g., Node) in which case script_id will be -1.
	
	var key_class_name := &""
	var key_script_id := -1
	if key_type == TYPE_OBJECT:
		key_class_name = dict.get_typed_key_class_name()
		var key_script: Script = dict.get_typed_key_script()
		if key_script:
			key_script_id = _get_script_id(key_script)
	
	var value_class_name := &""
	var value_script_id := -1
	if value_type == TYPE_OBJECT:
		value_class_name = dict.get_typed_value_class_name()
		var value_script: Script = dict.get_typed_value_script()
		if value_script:
			value_script_id = _get_script_id(value_script)
	
	# Note: it's ok if TYPE_KEY exists as key in project dictionaries because
	# _get_encoded_value(key) will never return that value.
	var encoded_dict := {TYPE_KEY : [key_type, key_class_name, key_script_id,
			value_type, value_class_name, value_script_id]}
	
	for key: Variant in dict:
		var encoded_key: Variant = _get_encoded_value(key)
		encoded_dict[encoded_key] = _get_encoded_value(dict[key])
	
	return encoded_dict


func _get_decoded_dict(encoded_dict: Dictionary) -> Dictionary:
	
	const TYPE_KEY := "" # same as _get_encoded_dict()
	
	if encoded_dict.is_typed(): # only "safe" types!
		return encoded_dict.duplicate()
	
	var dict_typing: Array = encoded_dict[TYPE_KEY]
	var key_type: int = dict_typing[0]
	var key_class_name: StringName = dict_typing[1]
	var key_script_id: int = dict_typing[2]
	var key_script := _scripts[key_script_id] if key_script_id != -1 else null
	var value_type: int = dict_typing[3]
	var value_class_name: StringName = dict_typing[4]
	var value_script_id: int = dict_typing[5]
	var value_script := _scripts[value_script_id] if value_script_id != -1 else null
	
	var dict := Dictionary({}, key_type, key_class_name, key_script,
			value_type, value_class_name, value_script)
	
	for encoded_key: Variant in encoded_dict:
		if is_same(encoded_key, TYPE_KEY):
			continue
		var key: Variant = _get_decoded_value(encoded_key)
		dict[key] = _get_decoded_value(encoded_dict[encoded_key])
	
	return dict


func _get_encoded_object(object: Object) -> String:
	var is_weak_ref := false
	if object is WeakRef:
		var wr: WeakRef = object
		object = wr.get_ref()
		if object == null:
			return "!" # WeakRef to a dead object
		is_weak_ref = true
	var object_id: int = _object_ids.get(object, -1)
	if object_id == -1:
		# We should have indexed all Nodes already.
		assert(object is RefCounted, "Possible reference to Node that is not in the tree")
		var ref: RefCounted = object
		object_id = _index_and_serialize_ref(ref)
	if is_weak_ref:
		return "!" + str(object_id) # WeakRef
	return "*" + str(object_id) # Object


func _get_decoded_object(encoded_object: String) -> Object:
	# Inverse encoding above.
	if encoded_object[0] == "*":
		return _objects[int(encoded_object.to_int())] # ignores "*"
	if encoded_object == "!":
		return WeakRef.new() # weak ref to dead object
	assert(encoded_object[0] == "!")
	return weakref(_objects[int(encoded_object.to_int())]) # ignores "!"


func _dprint(arg: Variant, arg2: Variant = "", arg3: Variant = "", arg4: Variant = "") -> bool:
	prints(arg, arg2, arg3, arg4)
	return true
