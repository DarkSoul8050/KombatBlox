--!strict
local root = script.Parent
local controllers = {
	require(root.Input.InputController),
	require(root.Camera.CameraController),
	require(root.UI.UIController),
	require(root.Combat.CombatController),
}
for _, c in controllers do c:Init() end
for _, c in controllers do task.spawn(c.Start, c) end
print("[KombatBlox] Cliente iniciado")
