extends Control

@export_category("UI References")
@export var server_list: ItemList
@export var refresh_btn: Button
@export var direct_ip: LineEdit
@export var join_btn: Button
@export var create_btn: Button
@export var exit_btn: Button

var udp_peer := PacketPeerUDP.new()
var listen_port = 7001

var found_servers = {} # IP -> Dictionary{"name", "last_seen"}
var cleanup_timer: Timer

func _ready():
	if refresh_btn: refresh_btn.pressed.connect(_refresh)
	if join_btn: join_btn.pressed.connect(_on_join)
	if create_btn: create_btn.pressed.connect(_on_create)
	if exit_btn: exit_btn.pressed.connect(_on_exit)
	
	cleanup_timer = Timer.new()
	cleanup_timer.wait_time = 1.0
	cleanup_timer.autostart = true
	cleanup_timer.timeout.connect(_clean_dead_servers)
	add_child(cleanup_timer)

	_refresh()
	Localization.retranslate_tree(self)

func _refresh():
	found_servers.clear()
	if server_list: server_list.clear()
	
	udp_peer.close()
	udp_peer.bind(listen_port)

func _process(_delta):
	if udp_peer.get_available_packet_count() > 0:
		var packet = udp_peer.get_packet().get_string_from_utf8()
		var ip = udp_peer.get_packet_ip()
		
		var is_new = not found_servers.has(ip)
		
		found_servers[ip] = {
			"name": packet,
			"last_seen": Time.get_ticks_msec()
		}
		
		if is_new:
			_update_ui_list()

func _update_ui_list():
	if not server_list: return
	server_list.clear()
	for ip in found_servers:
		var s_name = found_servers[ip]["name"]
		server_list.add_item(s_name + " (" + ip + ")")
		server_list.set_item_metadata(server_list.item_count - 1, ip)

func _clean_dead_servers():
	var current_time = Time.get_ticks_msec()
	var changed = false
	
	for ip in found_servers.keys():
		if current_time - found_servers[ip]["last_seen"] > 3000:
			found_servers.erase(ip)
			changed = true
			
	if changed:
		_update_ui_list()

func _on_join():
	var ip = ""
	if direct_ip:
		ip = direct_ip.text.strip_edges()
	
	if server_list and server_list.get_selected_items().size() > 0:
		var idx = server_list.get_selected_items()[0]
		ip = server_list.get_item_metadata(idx)
		
	if ip.is_empty():
		ip = "127.0.0.1"
		
	udp_peer.close()
		
	if NetworkManager.join_game(ip):
		get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	else:
		print("Failed to join!")

func _on_create():
	udp_peer.close()
	if NetworkManager.host_game(NetworkManager.DEFAULT_PORT, PlayerManager.local_profile.get("name", "Server")):
		PlayerManager.host_setup()
		get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	else:
		print("Failed to host!")

func _on_exit():
	udp_peer.close()
	get_tree().change_scene_to_file("res://scenes/login_menu.tscn")
