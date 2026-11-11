extends SceneTree
## Prints app/tests/layout/matrix.gd as one JSON line ("MATRIX [...]") for run.py.

func _initialize() -> void:
	var rows := []
	for r in load("res://tests/layout/matrix.gd").rows():
		rows.append({"id": r["id"], "size": [r["size"].x, r["size"].y], "layout": [r["layout"].x, r["layout"].y],
			"scale": r["scale"], "kind": r["screen"]["kind"], "diagonal_in": r["screen"]["diagonal_in"],
			"note": r["note"], "devices": r["devices"], "ci": r["ci"]})
	print("MATRIX " + JSON.stringify(rows))
	quit()
