-- UIController (cliente): HUD de partida (v1.0b).
-- SOLO representa. La fuente de verdad es el snapshot de MatchStateChanged (contrato v1).
-- Barras: fighter propio (izquierda) y rival (derecha). Espectador: A izquierda, B derecha.
-- Mantiene el polish de v0.9.1: DamageTrail, flash, sacudida de panel, K.O., pulso de DASH.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local CombatConfig = require(KB.Modules.CombatConfig)
local CombatEvent = SharedUtil.GetRemote("Combat", "CombatEvent")
local MatchStateChanged = SharedUtil.GetRemote("Match", "MatchStateChanged")
local GetMatchState = SharedUtil.GetRemote("Match", "GetMatchState")

local LocalPlayer = Players.LocalPlayer

local HUD_CFG = {
	TopOffset = 64,            -- px: por debajo de la barra superior de Roblox
	FillTween = 0.08,          -- la barra principal baja casi al instante
	TrailDelay = 0.35,         -- la franja de dano espera antes de consumirse
	TrailDuration = 0.4,       -- y se consume en este tiempo
	StrongHitRatio = 0.12,     -- perdida >= 12% de la vida maxima = flash fuerte
	FightBannerTime = 0.9,     -- segundos que se ve FIGHT!
	RefetchDelay = 0.5,        -- espera antes de volver a pedir el snapshot (Model sin replicar)
	MaxRefetch = 6,            -- intentos maximos por estado
}

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
	Pip = Color3.fromRGB(255, 205, 70),
	Fight = Color3.fromRGB(255, 220, 60),
	Victory = Color3.fromRGB(255, 205, 70),
	Defeat = Color3.fromRGB(170, 170, 185),
	Energy = Color3.fromRGB(90, 170, 255),
}

local REASON_TEXT = {
	KO = "K.O.",
	DoubleKO = "DOUBLE K.O.",
	Time = "TIME",
	Draw = "DRAW",
}

-- Estilos de cartel: From -> (Peak) -> 1
local STYLES = {
	Count   = { From = 1.4, Peak = nil,  In = 0.18, Settle = 0,    Color = COLORS.Text,    TextSize = 96 },
	Round   = { From = 0.8, Peak = 1.05, In = 0.15, Settle = 0.12, Color = COLORS.Text,    TextSize = 44 },
	Fight   = { From = 0.7, Peak = 1.15, In = 0.12, Settle = 0.1,  Color = COLORS.Fight,   TextSize = 110 },
	Impact  = { From = 1.5, Peak = nil,  In = 0.12, Settle = 0,    Color = COLORS.KO,      TextSize = 110, Shake = "Heavy" },
	Result  = { From = 0.8, Peak = 1.05, In = 0.15, Settle = 0.12, Color = COLORS.Text,    TextSize = 96 },
	Victory = { From = 0.6, Peak = 1.1,  In = 0.25, Settle = 0.15, Color = COLORS.Victory, TextSize = 130 },
	Defeat  = { From = 0.6, Peak = 1.1,  In = 0.25, Settle = 0.15, Color = COLORS.Defeat,  TextSize = 130 },
}

local UIController = {}

-- Elementos
local combatRoot       -- barras + marcador + temporizador (se oculta en Waiting)
local leftBar
local rightBar
local timerLabel
local energyBar        -- v1.4: barra de energia propia
local banner           -- cartel principal
local roundBanner      -- cartel de ronda
local indicators = {}
local leftConns = {}
local rightConns = {}

-- Estado derivado del snapshot
local snapshot = nil
local leftFighter = nil
local rightFighter = nil
local amFighter = false
local lastKey = nil
local lastCountdownNumber = nil
local fightBannerUntil = nil
local refetchPending = false
local refetchCount = 0

------------------------------------------------------------------
-- Utilidades
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

-- Sacudida generica de un GuiObject alrededor de su posicion base
local function shakeGui(holder, gui, level)
	local params = SHAKE[level]
	if not params then
		return
	end
	holder.ShakeToken += 1
	local token = holder.ShakeToken
	local basePos = holder.BasePos

	task.spawn(function()
		local start = os.clock()
		while holder.ShakeToken == token do
			local t = os.clock() - start
			if t >= params.Duration then
				break
			end
			local decay = 1 - t / params.Duration
			local ox = (math.random() * 2 - 1) * params.Amplitude * decay
			local oy = (math.random() * 2 - 1) * params.Amplitude * 0.5 * decay
			gui.Position = basePos + UDim2.fromOffset(ox, oy)
			RunService.RenderStepped:Wait()
		end
		if holder.ShakeToken == token then
			gui.Position = basePos
		end
	end)
end

------------------------------------------------------------------
-- Barras de vida (polish v0.9.1) + marcador de rondas
------------------------------------------------------------------
local function createBar(parent, side)
	local isRight = side == "Right"
	local basePos = UDim2.new(isRight and 0.98 or 0.02, 0, 0, HUD_CFG.TopOffset)

	local panel = make("Frame", {
		Name = side .. "Panel",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(isRight and 1 or 0, 0),
		Position = basePos,
		Size = UDim2.new(0.36, 0, 0, 78),
	}, parent)
	make("UISizeConstraint", { MaxSize = Vector2.new(460, 78) }, panel)

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

	-- Marcador de rondas: propio "● ○" (llena desde fuera), rival "○ ●" (espejo)
	local pipsFrame = make("Frame", {
		Name = "RoundPips",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 60),
		Size = UDim2.new(1, 0, 0, 16),
	}, panel)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = isRight and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, pipsFrame)

	return {
		Side = side,
		Panel = panel,
		BasePos = basePos,
		Fill = fill,
		Trail = trail,
		Flash = flashFrame,
		Name = nameLabel,
		Value = valueLabel,
		KO = koTag,
		Pips = { Frame = pipsFrame, Dots = {} },
		Ratio = 1,
		FillTween = nil,
		TrailTween = nil,
		TrailDraining = false,
		TrailToken = 0,
		FlashTween = nil,
		ShakeToken = 0,
		BoundModel = nil,
		BindToken = 0,
	}
end

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

local function snapTrail(bar, ratio)
	bar.TrailToken += 1
	if bar.TrailTween then
		bar.TrailTween:Cancel()
	end
	bar.TrailDraining = false
	bar.Trail.Size = UDim2.fromScale(ratio, 1)
end

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
		-- La franja representa la vida al inicio de la secuencia de golpes actual
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
		snapTrail(bar, ratio)
	end
end

local function setPips(bar, wins, total)
	local pips = bar.Pips
	if #pips.Dots ~= total then
		for _, dot in pips.Dots do
			dot:Destroy()
		end
		table.clear(pips.Dots)
		for i = 1, total do
			local dot = make("Frame", {
				Name = "Pip" .. i,
				Size = UDim2.fromOffset(14, 14),
				BackgroundColor3 = COLORS.Pip,
				BorderSizePixel = 0,
				LayoutOrder = i,
			}, pips.Frame)
			make("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
			make("UIStroke", { Color = COLORS.Pip, Thickness = 2 }, dot)
			table.insert(pips.Dots, dot)
		end
	end
	for i, dot in pips.Dots do
		local filled
		if bar.Side == "Left" then
			filled = i <= wins
		else
			filled = i > total - wins
		end
		dot.BackgroundTransparency = filled and 0 or 1
	end
end

-- Enlaza la barra al Humanoid del Model del fighter (desconecta el anterior).
local function bindBar(bar, conns, model)
	disconnectAll(conns)
	bar.BindToken += 1
	local token = bar.BindToken
	bar.BoundModel = model
	setKO(bar, false)

	if not model then
		bar.Value.Text = ""
		return
	end

	task.spawn(function()
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum then
			local found = model:WaitForChild("Humanoid", 5)
			if found and found:IsA("Humanoid") then
				hum = found
			end
		end
		if bar.BindToken ~= token or not hum then
			return
		end

		setBar(bar, hum.Health, hum.MaxHealth, true)
		setKO(bar, hum.Health <= 0)

		table.insert(conns, hum.HealthChanged:Connect(function(hp)
			setBar(bar, hp, hum.MaxHealth, false)
		end))
		table.insert(conns, hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
			setBar(bar, hum.Health, hum.MaxHealth, false)
		end))
		table.insert(conns, hum.Died:Connect(function()
			setKO(bar, true)
		end))
	end)
end

-- Solo re-enlaza si el Model cambio (un snapshot repetido no reinicia la franja)
local function syncBar(bar, conns, fighter)
	bar.Name.Text = fighter.Name or "-"
	if bar.BoundModel ~= fighter.Model then
		bindBar(bar, conns, fighter.Model)
	end
end

------------------------------------------------------------------
-- Carteles
------------------------------------------------------------------
local function createBanner(parent, name, yScale, height)
	local label = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, yScale),
		Size = UDim2.new(0, 900, 0, height),
		Font = Enum.Font.GothamBlack,
		TextSize = 96,
		TextColor3 = COLORS.Text,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Text = "",
		Visible = false,
		ZIndex = 20,
	}, parent)
	local scale = make("UIScale", { Scale = 1 }, label)
	return {
		Label = label,
		Scale = scale,
		BasePos = label.Position,
		Tweens = {},
		ShakeToken = 0,
	}
end

local function cancelTweens(b)
	for _, t in b.Tweens do
		t:Cancel()
	end
	table.clear(b.Tweens)
end

local function playTween(b, inst, info, props)
	local t = TweenService:Create(inst, info, props)
	table.insert(b.Tweens, t)
	t:Play()
	return t
end

local function showBanner(b, text, styleName)
	local st = STYLES[styleName]
	cancelTweens(b)
	b.ShakeToken += 1
	b.Label.Position = b.BasePos
	b.Label.Text = text
	b.Label.TextColor3 = st.Color
	b.Label.TextSize = st.TextSize
	b.Label.Visible = true
	b.Label.TextTransparency = 1
	b.Label.TextStrokeTransparency = 1
	b.Scale.Scale = st.From

	playTween(b, b.Label, TweenInfo.new(st.In, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = 0,
	})
	local grow = playTween(b, b.Scale, TweenInfo.new(st.In, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Scale = st.Peak or 1,
	})
	if st.Peak then
		grow.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				playTween(b, b.Scale, TweenInfo.new(st.Settle, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Scale = 1,
				})
			end
		end)
	end
	if st.Shake then
		shakeGui(b, b.Label, st.Shake)
	end
end

local function hideBanner(b, fade)
	cancelTweens(b)
	if not b.Label.Visible then
		return
	end
	local t = playTween(b, b.Label, TweenInfo.new(fade or 0.2), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	t.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			b.Label.Visible = false
		end
	end)
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

------------------------------------------------------------------
-- Energia (v1.4): barra del recurso propio. SOLO representacion: el valor real
-- lo fija el servidor en los atributos KB_Energy / KB_MaxEnergy del personaje.
------------------------------------------------------------------
local function createEnergyBar(parent)
	local holder = make("Frame", {
		Name = "EnergyBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -136),
		Size = UDim2.new(0, 260, 0, 14),
		BackgroundColor3 = COLORS.BarBack,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, parent)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, holder)
	make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.4 }, holder)

	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.Energy,
		BorderSizePixel = 0,
	}, holder)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)

	local label = make("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = COLORS.Text,
		TextStrokeTransparency = 0.5,
		Text = "",
		ZIndex = 2,
	}, holder)

	return { Frame = holder, Fill = fill, Label = label, Shown = 0 }
end

-- Lee los atributos del personaje propio y suaviza el relleno (la regeneracion del
-- servidor llega a ~5 Hz; el suavizado es solo visual).
local function updateEnergy(dt)
	local bar = energyBar
	if not bar then
		return
	end
	local character = LocalPlayer.Character
	local current = character and character:GetAttribute("KB_Energy")
	local maxValue = character and character:GetAttribute("KB_MaxEnergy")
	if typeof(current) ~= "number" or typeof(maxValue) ~= "number" or maxValue <= 0 then
		bar.Frame.Visible = false
		return
	end

	bar.Frame.Visible = true
	local alpha = 1 - math.exp(-dt * 12)
	bar.Shown += (current - bar.Shown) * alpha
	local ratio = math.clamp(bar.Shown / maxValue, 0, 1)
	bar.Fill.Size = UDim2.fromScale(ratio, 1)
	bar.Label.Text = ("%d / %d"):format(math.floor(bar.Shown + 0.5), math.floor(maxValue))
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
-- Snapshot -> HUD
------------------------------------------------------------------
-- Propio a la izquierda y rival a la derecha. Si no soy fighter: A izquierda, B derecha.
local function resolveFighters(snap)
	local fighters = snap.Fighters
	local A = fighters and fighters.A
	local B = fighters and fighters.B
	if not (A and B) then
		return nil, nil, false
	end
	if A.Player == LocalPlayer then
		return A, B, true
	end
	if B.Player == LocalPlayer then
		return B, A, true
	end
	return A, B, false
end

local applySnapshot

local function scheduleRefetch()
	if refetchPending or refetchCount >= HUD_CFG.MaxRefetch then
		return
	end
	refetchPending = true
	refetchCount += 1
	task.delay(HUD_CFG.RefetchDelay, function()
		refetchPending = false
		local ok, snap = pcall(function()
			return GetMatchState:InvokeServer()
		end)
		if ok and snap then
			applySnapshot(snap)
		end
	end)
end

local function onStateEnter(snap)
	lastCountdownNumber = nil
	fightBannerUntil = nil
	refetchCount = 0

	local state = snap.State
	if state == "Waiting" then
		hideBanner(banner, 0.3)
		hideBanner(roundBanner, 0.3)

	elseif state == "Countdown" then
		-- ROUND N durante toda la cuenta atras; los numeros los pone renderTick
		showBanner(roundBanner, ("ROUND %d"):format(snap.Round or 1), "Round")
		hideBanner(banner, 0.1)

	elseif state == "Fighting" then
		hideBanner(roundBanner, 0.2)
		showBanner(banner, "FIGHT!", "Fight")
		fightBannerUntil = os.clock() + HUD_CFG.FightBannerTime

	elseif state == "RoundEnd" then
		hideBanner(roundBanner, 0.1)
		local result = snap.RoundResult
		local reason = result and result.Reason
		local style = if reason == "KO" or reason == "DoubleKO" then "Impact" else "Result"
		showBanner(banner, REASON_TEXT[reason] or "", style)

	elseif state == "MatchEnd" then
		hideBanner(roundBanner, 0.1)
		-- El servidor decide el ganador; la UI no compara vidas
		local result = snap.MatchResult
		local winnerId = result and result.WinnerId
		if not winnerId then
			showBanner(banner, "DRAW", "Result")
		elseif amFighter and leftFighter then
			if winnerId == leftFighter.Id then
				showBanner(banner, "VICTORY", "Victory")
			else
				showBanner(banner, "DEFEAT", "Defeat")
			end
		else
			local winner = nil
			if leftFighter and leftFighter.Id == winnerId then
				winner = leftFighter
			elseif rightFighter and rightFighter.Id == winnerId then
				winner = rightFighter
			end
			showBanner(banner, string.upper((winner and winner.Name) or "?") .. " WINS", "Result")
		end
	end
end

applySnapshot = function(snap)
	if typeof(snap) ~= "table" then
		return
	end
	snapshot = snap
	local left, right, isFighter = resolveFighters(snap)
	leftFighter = left
	rightFighter = right
	amFighter = isFighter

	if snap.State == "Waiting" or not (left and right) then
		-- Sin partida real: HUD de combate oculto
		combatRoot.Visible = false
		if leftBar.BoundModel then
			bindBar(leftBar, leftConns, nil)
		end
		if rightBar.BoundModel then
			bindBar(rightBar, rightConns, nil)
		end
	else
		combatRoot.Visible = true
		syncBar(leftBar, leftConns, left)
		syncBar(rightBar, rightConns, right)
		local total = snap.RoundsToWin or 2
		setPips(leftBar, left.RoundWins or 0, total)
		setPips(rightBar, right.RoundWins or 0, total)

		-- Un Model sin replicar llega como nil: se vuelve a pedir el snapshot
		if not (left.Model and right.Model) then
			scheduleRefetch()
		end
	end

	local key = ("%s:%s:%s"):format(tostring(snap.MatchId), tostring(snap.State), tostring(snap.Round))
	if key ~= lastKey then
		lastKey = key
		onStateEnter(snap)
	end
end

-- Temporizador y cuenta atras: recalculados cada frame a partir del reloj del servidor
local function renderTick(dt)
	updateEnergy(dt or 0)   -- v1.4: la energia se pinta siempre que haya personaje

	local snap = snapshot
	if not snap or snap.State == "Waiting" then
		timerLabel.Visible = false
		return
	end

	local remaining = 0
	if snap.StateEndsAt then
		remaining = math.max(0, snap.StateEndsAt - workspace:GetServerTimeNow())
	end

	if snap.State == "Fighting" then
		timerLabel.Visible = true
		timerLabel.Text = ("%02d"):format(math.ceil(remaining))
		if fightBannerUntil and os.clock() >= fightBannerUntil then
			fightBannerUntil = nil
			hideBanner(banner, 0.25)
		end
	else
		timerLabel.Visible = false
	end

	if snap.State == "Countdown" then
		local n = math.max(1, math.ceil(remaining))
		if n ~= lastCountdownNumber then
			lastCountdownNumber = n
			showBanner(banner, tostring(n), "Count")
		end
	end
end

------------------------------------------------------------------
-- Eventos de combate (solo representacion)
-- HitConfirmed/GuardBroken.Victim = nombre del modelo; HitReceived/GuardBroken.Attacker = Player
------------------------------------------------------------------
local function onCombatEvent(data)
	if typeof(data) ~= "table" then
		return
	end

	if data.Type == "DashStarted" then
		if data.Target == LocalPlayer then
			startCooldown(indicators.Dash, CombatConfig.Dash.Cooldown)
		end
		return
	end

	-- v1.4: cooldown de habilidad (el servidor solo lo manda a quien la lanzo).
	if data.Type == "SkillUsed" then
		local indicator = indicators[data.Action]
		if indicator and (data.Cooldown or 0) > 0 then
			startCooldown(indicator, data.Cooldown)
		end
		return
	end

	-- Sacudidas: solo si soy fighter (el panel izquierdo es el mio)
	if not amFighter then
		return
	end
	local rivalModel = rightFighter and rightFighter.Model

	if data.Type == "HitConfirmed" then
		if rivalModel and data.Victim == rivalModel.Name then
			shakeGui(rightBar, rightBar.Panel, isFinisher(data.Action) and "Heavy" or "Light")
		end

	elseif data.Type == "HitReceived" then
		shakeGui(leftBar, leftBar.Panel, isFinisher(data.Action) and "Heavy" or "Light")

	elseif data.Type == "GuardBroken" then
		if data.Attacker == LocalPlayer then
			if rivalModel and data.Victim == rivalModel.Name then
				shakeGui(rightBar, rightBar.Panel, "Break")
			end
		else
			shakeGui(leftBar, leftBar.Panel, "Break")
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

	combatRoot = make("Frame", {
		Name = "Match",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	}, hud)

	leftBar = createBar(combatRoot, "Left")
	rightBar = createBar(combatRoot, "Right")

	timerLabel = make("TextLabel", {
		Name = "Timer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, HUD_CFG.TopOffset),
		Size = UDim2.new(0, 120, 0, 54),
		Font = Enum.Font.GothamBlack,
		TextSize = 44,
		TextColor3 = COLORS.Text,
		TextStrokeTransparency = 0,
		Text = "99",
		Visible = false,
	}, combatRoot)

	roundBanner = createBanner(hud, "RoundBanner", 0.3, 60)
	banner = createBanner(hud, "MainBanner", 0.42, 150)

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
	-- v1.4: habilidades. La clave coincide con el Action que manda el servidor.
	indicators.Skill1 = createIndicator(indicatorBar, "E")
	indicators.Skill2 = createIndicator(indicatorBar, "R")

	-- v1.4: barra de energia (recurso unico). El servidor es la autoridad; aqui
	-- solo se pinta el valor replicado en los atributos del personaje.
	energyBar = createEnergyBar(hud)

	CombatEvent.OnClientEvent:Connect(onCombatEvent)
	MatchStateChanged.OnClientEvent:Connect(applySnapshot)
	RunService.RenderStepped:Connect(renderTick)

	-- Entrada tardia: pedir el estado actual
	task.spawn(function()
		local ok, snap = pcall(function()
			return GetMatchState:InvokeServer()
		end)
		if ok and snap and not snapshot then
			applySnapshot(snap)
		end
	end)

	SharedUtil.Log("UI", "Match HUD v1.0b listo")
end

return UIController
