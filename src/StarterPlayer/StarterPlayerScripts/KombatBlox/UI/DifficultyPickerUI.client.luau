-- DifficultyPickerUI (cliente): selector rapido de dificultad del NPC (herramienta de practica).
-- Independiente del HUD (UIController). Manda la eleccion al servidor por Remotes/AI/SetDifficulty;
-- el servidor es quien fija el atributo autoritario KB_AIDifficulty. Refleja el valor real en vivo.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local AIConfig = require(KB:WaitForChild("Config"):WaitForChild("AIConfig"))

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local ORDER = { "Easy", "Normal", "Hard" }
local ATTR = AIConfig.DifficultyAttribute

local COLORS = {
	Panel = Color3.fromRGB(20, 20, 26),
	Idle = Color3.fromRGB(45, 45, 55),
	Active = Color3.fromRGB(255, 205, 70),
	Text = Color3.fromRGB(235, 235, 240),
	TextActive = Color3.fromRGB(20, 20, 26),
}

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in props do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local gui = make("ScreenGui", {
	Name = "KB_DifficultyPicker",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local panel = make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -16),
	Size = UDim2.new(0, 250, 0, 78),
	BackgroundColor3 = COLORS.Panel,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)
make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.4 }, panel)
make("UIPadding", {
	PaddingTop = UDim.new(0, 8),
	PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 10),
}, panel)

make("TextLabel", {
	Name = "Title",
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 18),
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = COLORS.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "DIFICULTAD DUMMY (Practice)",
}, panel)

local row = make("Frame", {
	Name = "Buttons",
	BackgroundTransparency = 1,
	Position = UDim2.new(0, 0, 0, 24),
	Size = UDim2.new(1, 0, 0, 36),
}, panel)
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Left,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 6),
}, row)

local buttons: {[string]: TextButton} = {}
for _, name in ORDER do
	local btn = make("TextButton", {
		Name = name,
		Size = UDim2.new(0, 72, 1, 0),
		BackgroundColor3 = COLORS.Idle,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = COLORS.Text,
		Text = name,
	}, row)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, btn)
	buttons[name] = btn
end

local function currentName(): string
	local raw = workspace:GetAttribute(ATTR)
	if typeof(raw) == "string" and AIConfig.Difficulties[raw] then
		return raw
	end
	return AIConfig.Default
end

local function refresh()
	local active = currentName()
	for name, btn in buttons do
		local on = name == active
		btn.BackgroundColor3 = on and COLORS.Active or COLORS.Idle
		btn.TextColor3 = on and COLORS.TextActive or COLORS.Text
	end
end

-- Remote (creado por el servidor en runtime). Esperarlo sin bloquear la UI.
local setDifficulty: RemoteEvent? = nil
task.spawn(function()
	local remotes = KB:WaitForChild("Remotes", 30)
	local aiFolder = remotes and remotes:WaitForChild("AI", 30)
	local remote = aiFolder and aiFolder:WaitForChild("SetDifficulty", 30)
	if remote and remote:IsA("RemoteEvent") then
		setDifficulty = remote
	end
end)

for name, btn in buttons do
	btn.Activated:Connect(function()
		if setDifficulty then
			setDifficulty:FireServer(name)
		end
	end)
end

workspace:GetAttributeChangedSignal(ATTR):Connect(refresh)
refresh()
