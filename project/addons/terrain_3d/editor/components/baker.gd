extends Node

const BakeLodDialog: PackedScene = preload("res://addons/terrain_3d/editor/components/bake_lod_dialog.tscn")
const BAKE_MESH_DESCRIPTION: String = "This will create a child MeshInstance3D. LOD4+ is recommended. LOD0 is slow and dense with vertices every 1 unit. It is not an optimal mesh."
const BAKE_OCCLUDER_DESCRIPTION: String = "This will create a child OccluderInstance3D. LOD4+ is recommended and will take 5+ seconds per region to generate. LOD0 is unnecessarily dense and slow."
const SET_UP_NAVIGATION_DESCRIPTION: String = "This operation will:

- Create a NavigationRegion3D node,
- Assign it a blank NavigationMesh resource,
- Move the Terrain3D node to be a child of the new node,
- And bake the nav mesh.

Once setup is complete, you can modify the settings on your nav mesh, and rebake
without having to run through the setup again.

If preferred, this setup can be canceled and the steps performed manually. For
the best results, adjust the settings on the NavigationMesh resource to match
the settings of your navigation agents and collisions."

var plugin: EditorPlugin
var bake_method: Callable
var bake_lod_dialog: ConfirmationDialog
var confirm_dialog: ConfirmationDialog


func _enter_tree() -> void:
	bake_lod_dialog = BakeLodDialog.instantiate()
	bake_lod_dialog.hide()
	bake_lod_dialog.confirmed.connect(func(): bake_method.call())
	bake_lod_dialog.set_unparent_when_invisible(true)
	
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.hide()
	confirm_dialog.confirmed.connect(func(): bake_method.call())
	confirm_dialog.set_unparent_when_invisible(true)


func _exit_tree():
	bake_lod_dialog.queue_free()
	confirm_dialog.queue_free()


func bake_mesh_popup() -> void:
	if plugin.terrain:
		bake_method = _bake_mesh
		bake_lod_dialog.description = BAKE_MESH_DESCRIPTION
		plugin.get_editor_interface().popup_dialog_centered(bake_lod_dialog)


func _bake_mesh() -> void:
	var mesh: Mesh = plugin.terrain.bake_mesh(bake_lod_dialog.lod, Terrain3DStorage.HEIGHT_FILTER_NEAREST)
	if !mesh:
		push_error("Failed to bake mesh from Terrain3D")
		return
	var undo := plugin.get_undo_redo()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = &"MeshInstance3D"
	mesh_instance.mesh = mesh
	mesh_instance.set_skeleton_path(NodePath())

	undo.create_action("Terrain3D Bake ArrayMesh")
	undo.add_do_method(plugin.terrain, &"add_child", mesh_instance, true)
	undo.add_undo_method(plugin.terrain, &"remove_child", mesh_instance)
	undo.add_do_property(mesh_instance, &"owner", plugin.terrain.owner)
	undo.add_do_reference(mesh_instance)
	undo.commit_action()


func bake_occluder_popup() -> void:
	if plugin.terrain:
		bake_method = _bake_occluder
		bake_lod_dialog.description = BAKE_OCCLUDER_DESCRIPTION
		plugin.get_editor_interface().popup_dialog_centered(bake_lod_dialog)


func _bake_occluder() -> void:
	var mesh: Mesh = plugin.terrain.bake_mesh(bake_lod_dialog.lod, Terrain3DStorage.HEIGHT_FILTER_MINIMUM)
	if !mesh:
		push_error("Failed to bake mesh from Terrain3D")
		return
	assert(mesh.get_surface_count() == 1)

	var undo := plugin.get_undo_redo()

	var occluder := ArrayOccluder3D.new()
	var arrays := mesh.surface_get_arrays(0)
	assert(arrays.size() > Mesh.ARRAY_INDEX)
	assert(arrays[Mesh.ARRAY_INDEX] != null)
	occluder.set_arrays(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_INDEX])

	var occluder_instance := OccluderInstance3D.new()
	occluder_instance.name = &"OccluderInstance3D"
	occluder_instance.occluder = occluder

	undo.create_action("Terrain3D Bake Occluder3D")
	undo.add_do_method(plugin.terrain, &"add_child", occluder_instance, true)
	undo.add_undo_method(plugin.terrain, &"remove_child", occluder_instance)
	undo.add_do_property(occluder_instance, &"owner", plugin.terrain.owner)
	undo.add_do_reference(occluder_instance)
	undo.commit_action()


func find_nav_region_terrains(nav_region: NavigationRegion3D) -> Array[Terrain3D]:
	var result: Array[Terrain3D] = []
	if not nav_region.navigation_mesh:
		return result
	
	var source_mode := nav_region.navigation_mesh.geometry_source_geometry_mode
	if source_mode == NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN:
		result.append_array(nav_region.find_children("", "Terrain3D", true, true))
		return result
	
	var group_nodes := nav_region.get_tree().get_nodes_in_group(nav_region.navigation_mesh.geometry_source_group_name)
	for node in group_nodes:
		if node is Terrain3D:
			result.push_back(node)
		if source_mode == NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN:
			result.append_array(node.find_children("", "Terrain3D", true, true))
	
	return result


func find_terrain_nav_regions(terrain: Terrain3D) -> Array[NavigationRegion3D]:
	var result: Array[NavigationRegion3D] = []
	var root := plugin.get_editor_interface().get_edited_scene_root()
	if not root:
		return result
	for nav_region in root.find_children("", "NavigationRegion3D", true, true):
		if find_nav_region_terrains(nav_region).has(terrain):
			result.push_back(nav_region)
	return result


func bake_nav_mesh() -> void:
	if plugin.nav_region:
		# A NavigationRegion3D is selected. We only need to bake that one navmesh.
		_bake_nav_region_nav_mesh(plugin.nav_region)
		print("Baking one NavigationMesh - finished.")
	
	elif plugin.terrain:
		# A Terrain3D is selected. There are potentially multiple navmeshes to bake and we need to
		# find them all. (The multiple navmesh use-case is likely on very large scenes with lots of
		# geometry. Each navmesh in this case would define its own, non-overlapping, baking AABB, to
		# cut down on the amount of geometry to bake. In a large open-world RPG, for instance, there
		# could be a navmesh for each town.)
		var nav_regions := find_terrain_nav_regions(plugin.terrain)
		for nav_region in nav_regions:
			_bake_nav_region_nav_mesh(nav_region)
		print("Baking %d NavigationMesh(es) - finished." % nav_regions.size())


func _bake_nav_region_nav_mesh(nav_region: NavigationRegion3D) -> void:
	var nav_mesh := nav_region.navigation_mesh
	assert(nav_mesh != null)
	
	var source_geometry_data := NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nav_mesh, source_geometry_data, nav_region)
	
	for terrain in find_nav_region_terrains(nav_region):
		var aabb := nav_mesh.filter_baking_aabb
		aabb.position += nav_mesh.filter_baking_aabb_offset
		aabb = nav_region.global_transform * aabb
		var faces := terrain.generate_nav_mesh_source_geometry(aabb)
		if not faces.is_empty():
			source_geometry_data.add_faces(faces, nav_region.global_transform.inverse())
	
	NavigationMeshGenerator.bake_from_source_geometry_data(nav_mesh, source_geometry_data)
	
	# Assign null first to force the debug display to actually update:
	nav_region.set_navigation_mesh(null)
	nav_region.set_navigation_mesh(nav_mesh)
	
	# Let other editor plugins and tool scripts know the nav mesh was just baked:
	nav_region.bake_finished.emit()


func set_up_navigation_popup() -> void:
	if plugin.terrain:
		bake_method = _set_up_navigation
		confirm_dialog.dialog_text = SET_UP_NAVIGATION_DESCRIPTION
		plugin.get_editor_interface().popup_dialog_centered(confirm_dialog)


func _set_up_navigation() -> void:
	assert(plugin.terrain)
	var terrain: Terrain3D = plugin.terrain
	
	var nav_region := NavigationRegion3D.new()
	nav_region.name = &"NavigationRegion3D"
	nav_region.navigation_mesh = NavigationMesh.new()
	
	var undo_redo := plugin.get_undo_redo()
	
	undo_redo.create_action("Terrain3D Set up Navigation")
	undo_redo.add_do_method(self, &"_do_set_up_navigation", nav_region, terrain)
	undo_redo.add_undo_method(self, &"_undo_set_up_navigation", nav_region, terrain)
	undo_redo.add_do_reference(nav_region)
	undo_redo.commit_action()

	plugin.get_editor_interface().inspect_object(nav_region)
	assert(plugin.nav_region == nav_region)
	
	bake_nav_mesh()


func _do_set_up_navigation(nav_region: NavigationRegion3D, terrain: Terrain3D) -> void:
	var parent := terrain.get_parent()
	var index := terrain.get_index()
	var owner := terrain.owner
	
	parent.remove_child(terrain)
	nav_region.add_child(terrain)
	
	parent.add_child(nav_region, true)
	parent.move_child(nav_region, index)
	
	nav_region.owner = owner
	terrain.owner = owner


func _undo_set_up_navigation(nav_region: NavigationRegion3D, terrain: Terrain3D) -> void:
	assert(terrain.get_parent() == nav_region)
	
	var parent := nav_region.get_parent()
	var index := nav_region.get_index()
	var owner := nav_region.get_owner()
	
	parent.remove_child(nav_region)
	nav_region.remove_child(terrain)
	
	parent.add_child(terrain, true)
	parent.move_child(terrain, index)
	
	terrain.owner = owner
