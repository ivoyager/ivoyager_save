# save.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2017-2025 Charlie Whitfield
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
extends Timer

## Singleton added as IVSave that provides API for saving and loading.
##
## Provides methods for save and load via file dialogs, quicksave, autosave,
## and quickload (load last savefile).[br][br]
##
## Callables [member save_permit], [member save_checkpoint], [member load_permit]
## and [member load_checkpoint] can be set to require permission tests and/or
## await "checkpoints" before proceding to save or load. Game state must be
## stable before save or load initiates (e.g., threads finished, etc.).[br][br]
##
## This node is a [Timer] to facilitate time-based autosaves. It is configured with
## [member Timer.ignore_time_scale] = true (and default [member Node.process_mode])
## so the timer will be real-time and pause/unpause with game state. Method
## [method start_autosave_timer] is provided to start the timer with interval
## time in minutes (or stop the timer with 0.0). For turn-based autosaves
## or other usage, call [method autosave] directly.[br][br]
##
## To process shortcut input, set [member input_enabled] = true and modify
## "input_shortcut_" properties as needed.[br][br]
##
## See [IVTreeSaver] for detailed comments on how to specify "persist"
## objects and properites in your project.

signal save_started()
signal save_finished()
signal load_started()
signal about_to_free_procedural_nodes()
signal about_to_build_procedural_tree_for_load()
signal load_finished()
signal status_changed(is_saving: bool, is_loading: bool)
signal dialog_opened(control: Control) # emitted by the dialog
signal dialog_closed(control: Control) # emitted by the dialog
signal save_dialog_requested()
signal load_dialog_requested()
signal close_dialogs_requested()


enum SaveType {
	NAMED_SAVE,
	QUICKSAVE,
	AUTOSAVE,
}

## Non-persist object.
const NO_PERSIST := IVSaveUtils.PersistMode.NO_PERSIST
## Object will not be freed (Node only; must have stable NodePath).
const PERSIST_PROPERTIES_ONLY := IVSaveUtils.PersistMode.PERSIST_PROPERTIES_ONLY
## Object will be freed and rebuilt on game load (Node or RefCounted).
const PERSIST_PROCEDURAL := IVSaveUtils.PersistMode.PERSIST_PROCEDURAL

## Set this constant to false to not assert in the case of unfreed procedural
## objects after load. Note that in debug/editor builds, the plugin will always
## register persist objects on save and before load, and then print a warning
## and a list if any of the pre-load procedural objects still exist after load.
const DEBUG_ASSERT_UNFREED_PROCEDURAL_OBJECTS := true
## Set true to print all persist objects on save.
const DEBUG_PRINT_PERSIST_OBJECTS_ON_SAVE := false
## Set true to print all persist objects before load.
const DEBUG_PRINT_PERSIST_OBJECTS_BEFORE_LOAD := false



## Read-only.
var is_saving: bool
## Read-only.
var is_loading: bool

# TODO: Replace save_root
# Root node(s) for save and load. If empty, class methods use the current scene
# root obtained by [code]get_tree().get_current_scene()[/code].
# Root nodes must have
# [code]const PERSIST_MODE := IVSaveUtils.PersistMode.PERSIST_PROPERTIES_ONLY[/code].
# Descendant nodes may have value [code]PERSIST_PROCEDURAL[/code] (see comments in IVTreeSaver).
#var save_roots: Array[NodePath] = []


## TODO: Replace w/ save_roots
## Root node for saving and loading. If null, class methods use
## get_tree().get_current_scene().
var save_root: Node = null

## The current saves directory. This value will be cached if different than
## [member fallback_directory].
var directory: String: get = get_directory, set = set_directory
## Cache path to persist the current save directory.
var directory_cache_path := "user://cache/saves_dir.ivbinary"
var fallback_directory := "user://saves"
var autosave_subdirectory := "autosaves"
var autosave_name := "Autosave"
var autosave_number := 10
## By default, autosaves will be named [member autosave_name] appended by an
## an integer from 1 to [member autosave_number]. Set this value to true to
## invoke callable [member suffix_generator] and set a different suffix.
var autosave_uses_suffix_generator := false 
var quicksave_name := "Quicksave"
## By default, the single quicksave file will be named [member quicksave_name]
## and will be overwritten. Set this value to true to invoke callable [member suffix_generator]
## to generate multiple named quicksaves.
var quicksave_uses_suffix_generator := false
var file_extension := "GameSave"
var file_description := "Game Save"


## Callable that supplies the base name for the save file.
var name_generator := func() -> String:
	return "Save"
## Callable that supplies a suffix for the save file name. The default
## placeholder method supplies a modified date-time string from the operating
## system in the form: "_YYYY-MM-DD_HH.MM.SS".
var suffix_generator := func() -> String:
	return "_" + Time.get_datetime_string_from_system().replace("T", "_").replace(":", ".")
## Callable must return true or false. If false, a save will not be initiated.
var save_permit := func() -> bool: return true
## Callable must return true or false. If false, a load will not be initiated.
var load_permit := func() -> bool: return true
## Callable, possibly a coroutine, awaited before save is started. Must return
## true or false; if false, the save is aborted. Use to ensure that game
## state is stable (threads finished, etc.) before save starts.
var save_checkpoint := func() -> bool: return true
## Callable, possibly a coroutine, awaited before load is started. Must return
## true or false; if false, the load is aborted. Use to ensure that game
## state is stable (threads finished, etc.) before load starts.
var load_checkpoint := func() -> bool: return true
## Frame delay that occurs after exising procedural nodes have been freed but
## before the loaded procedural tree is added. Can prevent hard-to-debug issues
## that result from freeing nodes responding to signals before they are fully
## destroyed.
var load_build_delay := 5

var input_enabled := false: get = get_input_enabled, set = set_input_enabled
var input_shortcut_save_as := &"save_as"
var input_shortcut_quicksave := &"quicksave"
var input_shortcut_load_file := &"load_file"
var input_shortcut_quickload := &"quickload"

var _directory: String # globalized path


@onready var _tree_saver := IVTreeSaver.new()


func _ready() -> void:
	# Make sure we have a directory and a place to cache user directory change.
	var dir_cache := FileAccess.open(directory_cache_path, FileAccess.READ)
	if !dir_cache:
		DirAccess.make_dir_recursive_absolute(directory_cache_path.get_base_dir())
	else:
		var cached_directory: String = dir_cache.get_var()
		if DirAccess.dir_exists_absolute(cached_directory):
			_directory = cached_directory
	if !_directory:
		_directory = ProjectSettings.globalize_path(fallback_directory)
		DirAccess.make_dir_recursive_absolute(_directory)
	timeout.connect(autosave)
	ignore_time_scale = true
	set_process_shortcut_input(input_enabled)


func _shortcut_input(event: InputEvent) -> void:
	if !event.is_action_type() or !event.is_pressed():
		return
	if event.is_action_pressed(input_shortcut_quicksave):
		quicksave()
	elif event.is_action_pressed(input_shortcut_save_as):
		save_file()
	elif event.is_action_pressed(input_shortcut_quickload):
		quickload()
	elif event.is_action_pressed(input_shortcut_load_file):
		load_file()
	else:
		return
	get_viewport().set_input_as_handled()


func get_input_enabled() -> bool:
	return input_enabled


func set_input_enabled(is_enabled: bool) -> void:
	set_process_shortcut_input(is_enabled)
	input_enabled = is_enabled


func get_file_name(save_type := SaveType.NAMED_SAVE) -> String:
	var base_name: String
	match save_type:
		SaveType.NAMED_SAVE:
			base_name = name_generator.call() + suffix_generator.call()
		SaveType.QUICKSAVE:
			base_name = quicksave_name
			if quicksave_uses_suffix_generator:
				base_name += suffix_generator.call()
		SaveType.AUTOSAVE:
			base_name = autosave_name
			if autosave_uses_suffix_generator:
				base_name += suffix_generator.call()
			else:
				base_name += get_autosave_integer_append()
	return base_name + "." + file_extension


func get_file_path(save_type := SaveType.NAMED_SAVE) -> String:
	if save_type == SaveType.AUTOSAVE:
		return get_autosaves_subdirectory().path_join(get_file_name(save_type))
	return get_directory().path_join(get_file_name(save_type))


func get_autosaves_subdirectory() -> String:
	return get_directory().path_join(autosave_subdirectory)


func get_directory() -> String:
	return _directory


func set_directory(dir_path: String) -> void:
	if dir_path == _directory:
		return
	var dir_cache := FileAccess.open(directory_cache_path, FileAccess.WRITE)
	if !dir_cache:
		push_error("Failed to open cache file for write at " + directory_cache_path)
		return
	dir_cache.store_var(dir_path)
	_directory = dir_path


## Path is constructed according to "quicksave_" properties.
func quicksave() -> void:
	save_file(SaveType.QUICKSAVE)


## Path is constructed according to "autosave_" properties.
func autosave() -> void:
	save_file(SaveType.AUTOSAVE)


## Load the last modified file at the cached directory (or its subdirectories),
## or request load dialog if there are none.
func quickload() -> void:
	load_file(true)


## Call with [param minutes] > 0.0 to start the autosave timer, or 0.0 to stop.
## To manage autosaves by external code, call [method autosave] as needed.
func start_autosave_timer(minutes: float) -> void:
	var seconds := maxf(minutes * 60, 0.0)
	if seconds == 0.0:
		stop()
		return
	start(seconds)


## Use default args to request save dialog. [param path] is used only if
## [code]save_type == SaveType.NAMED_SAVE[/code].
func save_file(save_type := SaveType.NAMED_SAVE, path := "") -> void:
	if is_loading or !save_permit.call():
		return
	if save_type != SaveType.NAMED_SAVE:
		path = get_file_path(save_type)
	if !path:
		save_dialog_requested.emit()
		return
	is_saving = true
	status_changed.emit(true, false)
	var checkpoint_return: Variant = await save_checkpoint.call()
	await get_tree().process_frame # ensure we are on the main thread
	assert(typeof(checkpoint_return) == TYPE_BOOL, "Callable 'save_checkpoint' must return a boolean")
	if !checkpoint_return:
		is_saving = false
		status_changed.emit(false, false)
		return
	print("Saving " + path)
	save_started.emit()
	await get_tree().process_frame
	var root := save_root if save_root else get_tree().get_current_scene()
	assert(IVSaveUtils.debug_register_persist_objects(root, DEBUG_PRINT_PERSIST_OBJECTS_ON_SAVE))
	var save_data: Array = _tree_saver.get_gamesave(root)
	_store_data_to_file(save_data, path)
	if save_type == SaveType.AUTOSAVE:
		trim_autosaves_subdirectory()
	save_finished.emit()
	is_saving = false
	status_changed.emit(false, false)


## Use default args to request load dialog. If [code]load_last == true[/code],
## then [param path] will be ignored.
func load_file(load_last := false, path := "") -> void:
	if is_saving or !load_permit.call():
		return
	if load_last:
		path = get_last_modified_file_path(get_directory()) # "" if no files found
	if !path:
		load_dialog_requested.emit()
		return
	if !FileAccess.file_exists(path):
		push_error("Could not find file for load: " + path)
		return
	is_loading = true
	status_changed.emit(false, true)
	var checkpoint_return: Variant = await load_checkpoint.call()
	await get_tree().process_frame # ensure we are on the main thread
	assert(typeof(checkpoint_return) == TYPE_BOOL, "Callable 'load_checkpoint' must return a boolean")
	if !checkpoint_return:
		is_loading = false
		status_changed.emit(false, false)
		return
	print("Loading " + path)
	var root := save_root if save_root else get_tree().get_current_scene()
	assert(IVSaveUtils.debug_register_persist_objects(root, DEBUG_PRINT_PERSIST_OBJECTS_BEFORE_LOAD))
	load_started.emit()
	about_to_free_procedural_nodes.emit()
	await get_tree().process_frame
	IVSaveUtils.free_procedural_nodes_recursive(root)
	for i in load_build_delay:
		await get_tree().process_frame
	assert(IVSaveUtils.debug_report_unfreed_procedural_objects(DEBUG_ASSERT_UNFREED_PROCEDURAL_OBJECTS))
	var save_data := _get_data_from_file(path)
	about_to_build_procedural_tree_for_load.emit()
	_tree_saver.build_attached_tree(save_data, root)
	load_finished.emit()
	is_loading = false
	status_changed.emit(false, false)


func has_file(path: String) -> bool:
	var dir := DirAccess.open(path)
	if !dir:
		return false
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name:
		if !dir.current_is_dir():
			if file_name.get_extension() == file_extension:
				return true
		else:
			if has_file(path.path_join(file_name)):
				return true
		file_name = dir.get_next()
	return false


func close_dialogs() -> void:
	close_dialogs_requested.emit()


## The search includes subdirectories.
func get_last_modified_file_path(dir_path: String) -> String:
	var path_time_result := ["", 0]
	_get_last_modified(dir_path, path_time_result)
	return path_time_result[0]


func get_autosave_integer_append() -> String:
	# Only examines the last modified file to decide the next integer append.
	var last_path_time := ["", 0]
	_get_last_modified(get_autosaves_subdirectory(), last_path_time, false)
	var last_modified: String = last_path_time[0]
	if !last_modified:
		return "-1"
	var base_name := last_modified.get_file().get_basename()
	var pos := base_name.rfind("-")
	if pos == -1:
		return "-1"
	var integer := base_name.substr(pos + 1).to_int()
	integer += 1
	if integer > autosave_number:
		integer = 1
	return "-" + str(integer)


func trim_autosaves_subdirectory() -> void:
	var list := _get_path_modified_time_list(get_autosaves_subdirectory())
	if list.size() <= autosave_number:
		return
	list.sort_custom(_sort_path_modified_time)
	while list.size() > autosave_number:
		var item: Array = list.pop_back()
		var path: String = item[0]
		DirAccess.remove_absolute(path)


func _get_path_modified_time_list(dir_path: String) -> Array[Array]:
	var list: Array[Array] = []
	var dir := DirAccess.open(dir_path)
	if !dir:
		return list
	dir.list_dir_begin()
	var next_name := dir.get_next()
	while next_name:
		if !dir.current_is_dir():
			if next_name.get_extension() == file_extension:
				var file_path := dir_path.path_join(next_name)
				var time := FileAccess.get_modified_time(file_path)
				list.append([file_path, time])
		next_name = dir.get_next()
	return list


func _sort_path_modified_time(a: Array, b: Array) -> bool:
	# more recent first
	return a[1] > b[1]


func _get_last_modified(dir_path: String, path_time_result: Array, search_subdirectories := true
		) -> void:
	# Searches subdirectories recursively
	var dir := DirAccess.open(dir_path)
	if !dir:
		return
	dir.list_dir_begin()
	var next_name := dir.get_next()
	while next_name:
		if !dir.current_is_dir():
			if next_name.get_extension() == file_extension:
				var file_path := dir_path.path_join(next_name)
				var time := FileAccess.get_modified_time(file_path)
				if time > path_time_result[1]:
					path_time_result[0] = file_path
					path_time_result[1] = time
		elif search_subdirectories:
			_get_last_modified(dir_path.path_join(next_name), path_time_result)
		next_name = dir.get_next()


func _store_data_to_file(save_data: Array, path: String) -> bool:
	# We create the directory in case it doesn't exist (e.g., no autosaves yet).
	var path_directory := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(path_directory)
	var file := FileAccess.open(path, FileAccess.WRITE)
	var err := FileAccess.get_open_error()
	if err != OK:
		return false
	file.store_var(save_data)
	return true


func _get_data_from_file(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	var err := FileAccess.get_open_error()
	if err != OK:
		return []
	return file.get_var()
