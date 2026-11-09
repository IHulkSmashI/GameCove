extends RefCounted
## Wake-on-LAN, the way Moonlight does it (moonlight-qt NvComputer::wake): the
## magic packet (6 x 0xFF, then the MAC 16 times) to every address we know the
## PC by, to 255.255.255.255 and to each network's broadcast address, on port 9
## (standard), 47009 (Moonlight Internet Hosting Tool) and GFE's 47998-48010
## (offset when the PC moved its HTTP port). UDP needs no privileges to send.
##
## The PC must have Wake-on-LAN on in its BIOS and network driver; over the
## internet it only works through a router or tool that forwards the packet.

const GameStream := preload("res://scripts/streaming/gamestream.gd")

const STATIC_PORTS := [9, 47009]
const DYNAMIC_PORTS := [47998, 47999, 48000, 48002, 48010]


static func magic_packet(mac: String) -> PackedByteArray:
	var out := PackedByteArray()
	if not GameStream.is_mac(mac):
		return out
	var raw := PackedByteArray()
	for part in mac.split(":"):
		raw.append(part.hex_to_int())
	for i in 6:
		out.append(0xFF)
	for i in 16:
		out.append_array(raw)
	return out


## [[address, port], ...] to send to. `addresses`: the PC's (names are fine;
## IPv6 skipped, no broadcast there); `broadcasts`: from `ip -o -4 addr`.
static func targets(addresses: Array, http_port: int, broadcasts: Array) -> Array:
	var out: Array = []
	var seen := {}
	var all: Array = []
	for a in addresses:
		if not str(a).contains(":"):
			all.append([str(a), true])
	all.append(["255.255.255.255", false])
	for b in broadcasts:
		if str(b) != "":
			all.append([str(b), false])
	for entry in all:
		var ports: Array = STATIC_PORTS.duplicate()
		if entry[1]:
			for p in DYNAMIC_PORTS:
				ports.append(p - GameStream.HTTP_PORT + (http_port if http_port > 0 else GameStream.HTTP_PORT))
		for p in ports:
			var k := "%s:%d" % [entry[0], p]
			if not seen.has(k):
				seen[k] = true
				out.append([entry[0], p])
	return out


## Sends the packet to every target. `send`: func(address, port, bytes) -> bool
## (tests); default real UDP. True when at least one send worked.
static func wake(mac: String, addresses: Array, http_port: int, broadcasts: Array, send: Callable = Callable()) -> bool:
	var pkt := magic_packet(mac)
	if pkt.is_empty():
		return false
	var fn := send if send.is_valid() else udp_send
	var ok := false
	for t in targets(addresses, http_port, broadcasts):
		if bool(fn.call(t[0], t[1], pkt)):
			ok = true
	return ok


static func udp_send(address: String, port: int, data: PackedByteArray) -> bool:
	var ip := address
	if not address.is_valid_ip_address():
		ip = IP.resolve_hostname(address, IP.TYPE_IPV4)
		if ip == "":
			return false
	var u := PacketPeerUDP.new()
	u.set_broadcast_enabled(true)
	if u.set_dest_address(ip, port) != OK:
		return false
	var ok := u.put_packet(data) == OK
	u.close()
	return ok
