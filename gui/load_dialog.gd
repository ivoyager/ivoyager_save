# load_dialog.gd
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
class_name IVLoadDialog
extends FileDialog



func _ready() -> void:
	add_filter("*." + IVSave.file_extension, IVSave.file_description)
	IVSave.load_dialog_requested.connect(_open)
	IVSave.close_dialogs_requested.connect(hide)
	file_selected.connect(_on_file_selected)
	visibility_changed.connect(_on_visibility_changed)


func _open() -> void:
	if visible:
		return
	popup_centered()
	current_dir = IVSave.get_directory()
	var last_modified := IVSave.get_last_modified_file_path(current_dir)
	if last_modified:
		print("IVLoadDialog: last_modified= ", last_modified)
		current_path = last_modified # this might set current_dir to the autosave dir!
		
		# Hack fix needed in Godot 4.5.betaX. OK button is disabled after path
		# set by code even if valid file...
		var ok_button := get_ok_button()
		ok_button.disabled = false
		
	else:
		deselect_all()


func _on_file_selected(path: String) -> void:
	# Set parent directory if this is autosave directory.
	var directory := current_dir
	if directory.get_file() == IVSave.autosave_subdirectory:
		directory = directory.get_base_dir()
	IVSave.set_directory(directory)
	IVSave.load_file(false, path)


func _on_visibility_changed() -> void:
	if visible:
		IVSave.dialog_opened.emit(self)
	else:
		IVSave.dialog_closed.emit(self)
