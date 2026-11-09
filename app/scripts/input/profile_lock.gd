extends RefCounted
## One lock for every read-modify-write of the InputPlumber profile (review M13): the
## Controls worker (controls/input/backend.gd ip_apply) and the Controller service's
## worker (input/controller.gd: start-up and game loads, its own setters) both edit the
## one loaded profile; without it an edit built on the profile from before the other's
## load replaced it.

static var mutex := Mutex.new()
