-- UIController (cliente): HUD de combate.
-- SOLO muestra informacion. No decide ni modifica nada del combate.
-- Rival (provisional hasta MatchService): Humanoid vivo mas cercano, con histeresis.
-- v0.9.1: K.O. limpia el contador, DamageTrail, flash, sacudida de panel, pulso de DASH.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local CombatConfig = require(KB.Modules.CombatConfig)
local CombatEvent = SharedUtil.GetRemote("Combat", "CombatEvent")

local LocalPlayer = Players.LocalPlayer

local HUD_CFG = {
	TopOffset = 64,            -- px: por debajo de la barra superior de Roblox
	RivalRange = 60,           -- studs: distancia maxima para considerar rival
	RivalSwitchRatio = 0.75,   -- otro candidato debe estar al 75% de la distancia actual
	RivalScanInterval = 0.25,  -- segundos entre busquedas de rival
	KODisplay = 2.5,           -- segundos que se muestra el K.O. del rival

	FillTween = 0.08,          -- la barra principal baja casi al instante
	TrailDelay = 0.35,         -- la franja de dano espera antes de consumirse
	TrailDuration = 0.4,       -- y se consume en este tiempo
	StrongHitRatio = 0.12,     -- perdida >= 12% de la vida maxima = flash fuerte
}

-- Sacudida del panel por nivel
local SHAKE = {
	Light = { Amplitude = 4, Duration = 0.15 },
	Heavy = { Amplitude = 9, Duration = 0.25 },
	Break = { Amplitude = 14, Duration = 0.35 },
}

local COLORS = {
	High = Color3.fromRGB(80, 220, 120),
	Mid = Color3.fromRGB(240, 200, 60),
	Low = Color3.fromRGB(230, 70, 70),
	Trail = Color3.fromRGB(255, 238, 200),
	BarBack = Color3.fromRGB(28, 28, 34),
	Text = Color3.fromRGB(255, 255, 255),
	KO = Color3.fromRGB(255, 60, 60),
	Ready = Color3.fromRGB(255, 255, 255),
	Cooling = Color3.fromRGB(120, 120, 130),
	Panel = Color3.fromRGB(20, 20, 26),
}

local UIController = {}

local selfBar
local rivalBar
local koLabel
local indicators = {}
local selfConns = {}
local rivalConns = {}
local rivalModel = nil
local rivalHum = nil

------------------------------------------------------------------
-- Utilidades de UI
------------------------------------------------------------------
local function make(className, props, parent)
	local inst = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function disconnectAll(list)
	for _, conn in list do
		conn:Disconnect()
	end
	table.clear(list)
end

local function healthColor(ratio)
	if ratio > 0.5 then
		return COLORS.High
	elseif ratio > 0.25 then
		return COLORS.Mid
	end
	return COLORS.Low
end

-- Remate = ultimo eslabon de su cadena (vale para combos futuros)
local function isFinisher(action)
	local cfg = CombatConfig.Actions[action]
	return cfg ~= nil and cfg.ComboNext == nil
end

local function getHudParent()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("KombatBlox", 10)
	local hud = gui and gui:FindFirstChild("HUD")

	local parent = hud
	if not parent then
		parent = make("ScreenGui", {
			Name = "KombatBloxHUD",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, playerGui)
	end

	local old = parent:FindFirstChild("CombatHUD")
	if old then
		old:Destroy()
	end
	return make("Frame", {
		Name = "CombatHUD",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, parent)
end

------------------------------------------------------------------
-- Barras de vida
------------------------------------------------------------------
local function createBar(parent, side)
	local isRight = side == "Right"
	local basePos = UDim2.new(isRight and 0.98 or 0.02, 0, 0, HUD_CFG.TopOffset)

	local panel = make("Frame", {
		Name = side .. "Panel",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(isRight and 1 or 0, 0),
		Position = basePos,
		Size = UDim2.new(0.36, 0, 0, 58),
	}, parent)
	make("UISizeConstraint", { MaxSize = Vector2.new(460, 58) }, panel)

	local nameLabel = make("TextLabel", {
		Name = "PlayerName",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = COLORS.Text,
		TextStrokeTransparency = 0.5,
		TextXAlignment = isRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
		Text = "-",
	}, panel)

	local back = make("Frame", {
		Name = "Bar",
		Position = UDim2.new(0, 0, 0, 26),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = COLORS.BarBack,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, panel)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, back)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.3 }, back)

	-- Ambas barras anclan al borde EXTERIOR y pierden vida hacia el centro.
	local anchor = Vector2.new(isRight and 1 or 0, 0)
	local anchorPos = UDim2.fromScale(isRight and 1 or 0, 0)

	-- Franja de dano retardado (debajo de la barra principal)
	local trail = make("Frame", {
		Name = "DamageTrail",
		AnchorPoint = anchor,
		Position = anchorPos,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.Trail,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, back)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, trail)

	local fill = make("Frame", {
		Name = "Fill",
		AnchorPoint = anchor,
		Position = anchorPos,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.High,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, back)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, fill)

	local valueLabel = make("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = COLORS.Text,
		TextStrokeTransparency = 0.4,
		Text = "",
		ZIndex = 3,
	}, back)

	local flashFrame = make("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, back)

	local koTag = make("TextLabel", {
		Name = "KO",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		TextColor3 = COLORS.KO,
		TextStrokeTransparency = 0,
		Text = "K.O.",
		Visible = false,
		ZIndex = 5,
	}, back)

	return {
		Panel = panel,
		BasePos = basePos,
		Fill = fill,
		Trail = trail,
		Flash = flashFrame,
		Name = nameLabel,
		Value = valueLabel,
		KO = koTag,
		Ratio = 1,
		FillTween = nil,
		TrailTween = nil,
		TrailDraining = false,
		TrailToken = 0,
		FlashTween = nil,
		ShakeToken = 0,
	}
end

-- K.O. y contador nunca se muestran a la vez
local function setKO(bar, on)
	bar.KO.Visible = on
	bar.Value.Visible = not on
end

local function flashBar(bar, strong)
	if bar.FlashTween then
		bar.FlashTween:Cancel()
	end
	bar.Flash.BackgroundTransparency = strong and 0.15 or 0.45
	bar.FlashTween = TweenService:Create(
		bar.Flash,
		TweenInfo.new(strong and 0.3 or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	bar.FlashTween:Play()
end

local function shakePanel(bar, level)
	local params = SHAKE[level]
	if not params then
		return
	end
	bar.ShakeToken += 1
	local token = bar.ShakeToken

	task.spawn(function()
		local start = os.clock()
		while bar.ShakeToken == token do
			local t = os.clock() - start
			if t >= params.Duration then
				break
			end
			local decay = 1 - t / params.Duration
			local ox = (math.random() * 2 - 1) * params.Amplitude * decay
			local oy = (math.random() * 2 - 1) * params.Amplitude * 0.5 * decay
			bar.Panel.Position = bar.BasePos + UDim2.fromOffset(ox, oy)
			RunService.RenderStepped:Wait()
		end
		if bar.ShakeToken == token then
			bar.Panel.Position = bar.BasePos
		end
	end)
end

-- Detiene la franja y la deja en 'ratio' (sin animacion)
local function snapTrail(bar, ratio)
	bar.TrailToken += 1
	if bar.TrailTween then
		bar.TrailTween:Cancel()
	end
	bar.TrailDraining = false
	bar.Trail.Size = UDim2.fromScale(ratio, 1)
end

-- instant = true: sin animacion (al enlazar un personaje nuevo)
local function setBar(bar, hp, maxHp, instant)
	local ratio = 0
	if maxHp > 0 then
		ratio = math.clamp(hp / maxHp, 0, 1)
	end
	local previous = bar.Ratio
	bar.Ratio = ratio
	bar.Value.Text = ("%d / %d"):format(math.max(0, math.ceil(hp)), math.floor(maxHp))

	local color = healthColor(ratio)
	if bar.FillTween then
		bar.FillTween:Cancel()
	end

	if instant then
		bar.Fill.Size = UDim2.fromScale(ratio, 1)
		bar.Fill.BackgroundColor3 = color
		snapTrail(bar, ratio)
		return
	end

	bar.FillTween = TweenService:Create(
		bar.Fill,
		TweenInfo.new(HUD_CFG.FillTween, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(ratio, 1), BackgroundColor3 = color }
	)
	bar.FillTween:Play()

	if ratio < previous then
		-- DANO. La franja representa SIEMPRE la vida al inicio de la secuencia actual:
		--   * esperando (combo en curso): no se toca -> acumula el dano del combo;
		--   * consumiendose (secuencia terminada): vuelve EXACTAMENTE a 'previous';
		--   * en reposo: ya coincide con 'previous'.
		if bar.TrailDraining then
			snapTrail(bar, previous)
		end

		bar.TrailToken += 1
		local token = bar.TrailToken
		task.delay(HUD_CFG.TrailDelay, function()
			if bar.TrailToken ~= token then
				return
			end
			bar.TrailDraining = true
			local tween = TweenService:Create(
				bar.Trail,
				TweenInfo.new(HUD_CFG.TrailDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = UDim2.fromScale(bar.Ratio, 1) }
			)
			tween.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed and bar.TrailToken == token then
					bar.TrailDraining = false
				end
			end)
			bar.TrailTween = tween
			tween:Play()
		end)

		flashBar(bar, (previous - ratio) >= HUD_CFG.StrongHitRatio)
	else
		-- CURACION o sin cambio: la franja acompana sin retraso
		snapTrail(bar, ratio)
	end
end

------------------------------------------------------------------
-- Indicadores (extensible: createIndicator("NOMBRE"))
------------------------------------------------------------------
local function createIndicator(parent, label)
	local frame = make("Frame", {
		Name = label,
		Size = UDim2.new(0, 110, 0, 34),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, parent)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, frame)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.4 }, frame)
	local scale = make("UIScale", { Scale = 1 }, frame)

	local text = make("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -8),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = COLORS.Ready,
		Text = label,
	}, frame)

	local barBack = make("Frame", {
		Name = "CooldownBack",
		Position = UDim2.new(0, 6, 1, -8),
		Size = UDim2.new(1, -12, 0, 4),
		BackgroundColor3 = COLORS.BarBack,
		BorderSizePixel = 0,
	}, frame)

	local fill = make("Frame", {
		Name = "CooldownFill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.Ready,
		BorderSizePixel = 0,
	}, barBack)

	return { Frame = frame, Label = text, Fill = fill, Scale = scale, Tween = nil, PulseTween = nil }
end

local function pulseIndicator(indicator)
	if indicator.PulseTween then
		indicator.PulseTween:Cancel()
	end
	indicator.Scale.Scale = 1
	local grow = TweenService:Create(
		indicator.Scale,
		TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = 1.18 }
	)
	local shrink = TweenService:Create(
		indicator.Scale,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = 1 }
	)
	grow.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			indicator.PulseTween = shrink
			shrink:Play()
		end
	end)
	indicator.PulseTween = grow
	grow:Play()
end

local function startCooldown(indicator, duration)
	if indicator.Tween then
		indicator.Tween:Cancel()
	end
	if indicator.PulseTween then
		indicator.PulseTween:Cancel()
	end
	indicator.Scale.Scale = 1
	indicator.Fill.Size = UDim2.fromScale(0, 1)
	indicator.Fill.BackgroundColor3 = COLORS.Cooling
	indicator.Label.TextColor3 = COLORS.Cooling

	local tween = TweenService:Create(
		indicator.Fill,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }
	)
	tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			indicator.Fill.BackgroundColor3 = COLORS.Ready
			indicator.Label.TextColor3 = COLORS.Ready
			pulseIndicator(indicator)
		end
	end)
	indicator.Tween = tween
	tween:Play()
end

------------------------------------------------------------------
-- Jugador propio
------------------------------------------------------------------
local function bindSelf(character)
	disconnectAll(selfConns)
	koLabel.Visible = false
	setKO(selfBar, false)

	local hum = character:WaitForChild("Humanoid", 10)
	if not (hum and hum:IsA("Humanoid")) then
		return
	end

	selfBar.Name.Text = LocalPlayer.DisplayName
	setBar(selfBar, hum.Health, hum.MaxHealth, true)

	table.insert(selfConns, hum.HealthChanged:Connect(function(hp)
		setBar(selfBar, hp, hum.MaxHealth, false)
	end))
	table.insert(selfConns, hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		setBar(selfBar, hum.Health, hum.MaxHealth, false)
	end))
	table.insert(selfConns, hum.Died:Connect(function()
		setKO(selfBar, true)
		koLabel.Visible = true
	end))
end

------------------------------------------------------------------
-- Rival
------------------------------------------------------------------
local bindRival

bindRival = function(model)
	disconnectAll(rivalConns)
	rivalModel = model
	rivalHum = model and model:FindFirstChildOfClass("Humanoid") or nil

	if not (model and rivalHum) then
		rivalModel = nil
		rivalHum = nil
		rivalBar.Panel.Visible = false
		return
	end

	rivalBar.Panel.Visible = true
	setKO(rivalBar, false)

	local rivalPlayer = Players:GetPlayerFromCharacter(model)
	rivalBar.Name.Text = rivalPlayer and rivalPlayer.DisplayName or model.Name

	local hum = rivalHum
	setBar(rivalBar, hum.Health, hum.MaxHealth, true)

	table.insert(rivalConns, hum.HealthChanged:Connect(function(hp)
		setBar(rivalBar, hp, hum.MaxHealth, false)
	end))
	table.insert(rivalConns, hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		setBar(rivalBar, hum.Health, hum.MaxHealth, false)
	end))
	table.insert(rivalConns, hum.Died:Connect(function()
		setKO(rivalBar, true)
		task.delay(HUD_CFG.KODisplay, function()
			if rivalModel == model then
				bindRival(nil)
			end
		end)
	end))
	table.insert(rivalConns, model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) and rivalModel == model then
			bindRival(nil)
		end
	end))
end

local scanParams = OverlapParams.new()
scanParams.FilterType = Enum.RaycastFilterType.Exclude

local function scanRival()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	if rivalHum and rivalHum.Health <= 0 then
		return
	end

	scanParams.FilterDescendantsInstances = { character }

	local best = nil
	local bestDist = math.huge
	local seen = {}
	for _, part in workspace:GetPartBoundsInRadius(root.Position, HUD_CFG.RivalRange, scanParams) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		if model and not seen[model] then
			seen[model] = true
			local hum = model:FindFirstChildOfClass("Humanoid")
			local mRoot = model:FindFirstChild("HumanoidRootPart")
			if hum and mRoot and hum.Health > 0 then
				local dist = (mRoot.Position - root.Position).Magnitude
				if dist < bestDist then
					best = model
					bestDist = dist
				end
			end
		end
	end

	local currentDist = math.huge
	if rivalModel and rivalHum and rivalHum.Health > 0 then
		local cRoot = rivalModel:FindFirstChild("HumanoidRootPart")
		if cRoot then
			currentDist = (cRoot.Position - root.Position).Magnitude
		end
	end

	if currentDist > HUD_CFG.RivalRange then
		if best ~= rivalModel then
			bindRival(best)
		end
	elseif best and best ~= rivalModel and bestDist < currentDist * HUD_CFG.RivalSwitchRatio then
		bindRival(best)
	end
end

------------------------------------------------------------------
-- Eventos de combate (solo representacion)
-- Formato verificado contra CombatService v0.8:
--   HitConfirmed: Victim = nombre del modelo (string)
--   HitReceived:  Attacker = Player
--   GuardBroken:  Victim = nombre del modelo (string), Attacker = Player
------------------------------------------------------------------
local function onCombatEvent(data)
	if typeof(data) ~= "table" then
		return
	end

	if data.Type == "DashStarted" then
		if data.Target == LocalPlayer then
			startCooldown(indicators.Dash, CombatConfig.Dash.Cooldown)
		end

	elseif data.Type == "HitConfirmed" then
		if rivalModel and data.Victim == rivalModel.Name then
			shakePanel(rivalBar, isFinisher(data.Action) and "Heavy" or "Light")
		end

	elseif data.Type == "HitReceived" then
		shakePanel(selfBar, isFinisher(data.Action) and "Heavy" or "Light")

	elseif data.Type == "GuardBroken" then
		if data.Attacker == LocalPlayer then
			if rivalModel and data.Victim == rivalModel.Name then
				shakePanel(rivalBar, "Break")
			end
		else
			shakePanel(selfBar, "Break")
		end
	end
end

------------------------------------------------------------------
-- Ciclo de vida
------------------------------------------------------------------
function UIController:Init()
end

function UIController:Start()
	local hud = getHudParent()

	selfBar = createBar(hud, "Left")
	rivalBar = createBar(hud, "Right")
	rivalBar.Panel.Visible = false

	koLabel = make("TextLabel", {
		Name = "KOBanner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.new(0, 400, 0, 120),
		Font = Enum.Font.GothamBlack,
		TextSize = 96,
		TextColor3 = COLORS.KO,
		TextStrokeTransparency = 0,
		Text = "K.O.",
		Visible = false,
		ZIndex = 10,
	}, hud)

	local indicatorBar = make("Frame", {
		Name = "Indicators",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.new(0, 400, 0, 40),
	}, hud)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
	}, indicatorBar)

	indicators.Dash = createIndicator(indicatorBar, "DASH")

	LocalPlayer.CharacterAdded:Connect(bindSelf)
	if LocalPlayer.Character then
		task.spawn(bindSelf, LocalPlayer.Character)
	end

	CombatEvent.OnClientEvent:Connect(onCombatEvent)

	task.spawn(function()
		while true do
			task.wait(HUD_CFG.RivalScanInterval)
			local ok, err = pcall(scanRival)
			if not ok then
				SharedUtil.Warn("UI", "scanRival: " .. tostring(err))
			end
		end
	end)

	SharedUtil.Log("UI", "Combat HUD v0.9.1 listo")
end

return UIController
