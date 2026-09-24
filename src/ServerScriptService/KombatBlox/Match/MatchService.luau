-- MatchService (servidor): NUCLEO de la partida. Rondas BO3 entre dos Fighters (Player o NPC).
-- Estados: Waiting -> Countdown -> Fighting -> RoundEnd -> (Countdown | MatchEnd) -> Waiting.
-- Contrato con clientes: MatchStateChanged (snapshot completo) + GetMatchState (mismo snapshot).
-- Contrato con CombatService: CanAct / CanDealDamage / CanReceiveDamage + CombatService.ResetFighter.
-- Respawn: Players.CharacterAutoLoads = false. MatchService es el UNICO que carga personajes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local MatchConfig = require(KB.Modules.MatchConfig)
local Characters = require(KB.Config.Characters)
local Registry = require(script.Parent.Parent.Services.ServiceRegistry)

local MatchStateChanged = SharedUtil.GetRemote("Match", "MatchStateChanged")
local GetMatchState = SharedUtil.GetRemote("Match", "GetMatchState")

local TAG = "Match"
local BLOCK_ATTR = "KB_Blocking"
local SNAPSHOT_VERSION = 1

local STATE = {
	Waiting = "Waiting",
	Countdown = "Countdown",
	Fighting = "Fighting",
	RoundEnd = "RoundEnd",
	MatchEnd = "MatchEnd",
}

local MatchService = {}

local CombatService = nil   -- se resuelve en Start
local match = nil           -- partida activa (una a la vez)
local nextMatchId = 0
local warnedSpawns = false
local loading = {}          -- [Player] = true mientras hay una carga en curso (cerrojo)

local function log(message)
	SharedUtil.Log(TAG, message)
end

local function serverNow()
	return workspace:GetServerTimeNow()
end

------------------------------------------------------------------
-- Carga de personajes (unico punto de respawn del juego)
------------------------------------------------------------------
-- Carga el personaje y ESPERA a que player.Character sea el nuevo (no el anterior).
-- Funciona tanto si LoadCharacterAsync/LoadCharacter ceden hasta el spawn como si no.
-- Limite: 5 s. NOTA: un forfeit durante esta carga se atiende al terminar (hasta 5 s),
-- no en <= 50 ms; esa garantia se aplica a las esperas de step().
local function doLoadCharacter(player)
	if player.Parent ~= Players then
		return nil
	end
	local old = player.Character

	local ok = pcall(function()
		player:LoadCharacterAsync()
	end)
	if not ok then
		ok = pcall(function()
			player:LoadCharacter()
		end)
	end
	if not ok then
		return nil
	end

	local started = os.clock()
	while player.Parent == Players and (player.Character == nil or player.Character == old) do
		if os.clock() - started > 5 then
			return nil
		end
		task.wait()
	end
	return player.Character
end

-- Cerrojo por jugador: NUNCA dos cargas simultaneas del mismo jugador.
-- Si hay una en curso (p. ej. la carga inicial de watchPlayer), se espera a que termine
-- y despues se hace la propia, con 'old' apuntando al personaje correcto.
local function loadCharacter(player)
	while loading[player] do
		if player.Parent ~= Players then
			return nil
		end
		task.wait()
	end
	loading[player] = true
	local ok, character = pcall(doLoadCharacter, player)
	loading[player] = nil
	if ok then
		return character
	end
	return nil
end

------------------------------------------------------------------
-- Fighters
------------------------------------------------------------------
local function getSpawn(id)
	local folder = workspace:FindFirstChild("KombatBlox")
	folder = folder and folder:FindFirstChild("SpawnPoints")
	local part = folder and folder:FindFirstChild("Spawn" .. id)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function newPlayerFighter(id, player)
	return {
		Id = id,
		Kind = "Player",
		Player = player,
		Model = nil,
		Humanoid = nil,
		Root = nil,
		DisplayName = player.DisplayName,
		SpawnPoint = getSpawn(id),
		RoundWins = 0,
	}
end

local function newNpcFighter(id)
	return {
		Id = id,
		Kind = "NPC",
		Player = nil,
		Model = nil,
		Humanoid = nil,
		Root = nil,
		DisplayName = MatchConfig.PracticeNpcName,
		SpawnPoint = getSpawn(id),
		RoundWins = 0,
	}
end

local function eachFighter(m)
	return { m.Fighters.A, m.Fighters.B }
end

local function otherId(id)
	return id == "A" and "B" or "A"
end

local function fighterByPlayer(player)
	if not match then
		return nil
	end
	for _, f in eachFighter(match) do
		if f.Player == player then
			return f
		end
	end
	return nil
end

local function fighterByModel(model)
	if not match then
		return nil
	end
	for _, f in eachFighter(match) do
		if f.Model == model then
			return f
		end
	end
	return nil
end

local function isDead(f)
	if not (f.Humanoid and f.Model) then
		return true
	end
	if not f.Model:IsDescendantOf(workspace) then
		return true
	end
	return f.Humanoid.Health <= 0
end

local function healthPct(f)
	if not f.Humanoid or f.Humanoid.MaxHealth <= 0 then
		return 0
	end
	return math.clamp(f.Humanoid.Health / f.Humanoid.MaxHealth, 0, 1)
end

------------------------------------------------------------------
-- Preparacion de fighters (spawn, vida completa, estado limpio)
------------------------------------------------------------------
local function floorY(position, ignore)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(position + Vector3.new(0, 5, 0), Vector3.new(0, -60, 0), params)
	if result then
		return result.Position.Y
	end
	return position.Y
end

-- Coloca el modelo de pie sobre el suelo del SpawnPoint, mirando hacia donde mira el SpawnPoint.
local function placeModel(model, spawnPart)
	local y = floorY(spawnPart.Position, { model, spawnPart.Parent })
	local look = spawnPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	local base = Vector3.new(spawnPart.Position.X, y, spawnPart.Position.Z)
	model:PivotTo(CFrame.lookAt(base, base + flat.Unit) + Vector3.new(0, 10, 0))

	-- Ajuste por bounding box: la base del modelo toca el suelo (vale para cualquier rig)
	local bbCFrame, bbSize = model:GetBoundingBox()
	local bottom = bbCFrame.Position.Y - bbSize.Y / 2
	model:PivotTo(model:GetPivot() - Vector3.new(0, bottom - y - 0.05, 0))
end

local function stripForceField(character)
	for _, child in character:GetChildren() do
		if child:IsA("ForceField") then
			child:Destroy()
		end
	end
end

local function setMovementLocked(f, locked)
	local hum = f.Humanoid
	if not (hum and hum.Parent) then
		return
	end

	if f.Kind == "Player" then
		if locked then
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
		else
			hum.WalkSpeed = f.WalkSpeed or StarterPlayer.CharacterWalkSpeed
			hum.JumpPower = StarterPlayer.CharacterJumpPower
			hum.JumpHeight = StarterPlayer.CharacterJumpHeight
		end
		return
	end

	-- NPC: locked = anclado y quieto (Countdown/RoundEnd); unlocked = fisica + locomocion.
	-- La IA (AIService/DummyBrain) solo mueve al NPC cuando esta unlocked (durante Fighting).
	local root = f.Root
	if locked then
		hum.WalkSpeed = 0
		if root then
			root.Anchored = true
		end
	else
		if root then
			root.Anchored = false
		end
		hum.WalkSpeed = f.WalkSpeed or StarterPlayer.CharacterWalkSpeed
	end
end

-- Limpia combo, bloqueo, dash, hitstun, stun y ataques en curso (jugador) o el bloqueo (NPC)
local function resetCombatState(f)
	if f.Kind == "Player" and f.Player and CombatService and CombatService.ResetFighter then
		local ok, err = pcall(CombatService.ResetFighter, f.Player)
		if not ok then
			SharedUtil.Warn(TAG, "ResetFighter: " .. tostring(err))
		end
	end
	if f.Model and f.Model.Parent then
		f.Model:SetAttribute(BLOCK_ATTR, false)
	end
end

local function buildNpcModel()
	-- 1) API async actual. 2) API clasica. 3) Respaldo minimo. Cada paso aislado en su pcall.
	local ok, rig = pcall(function()
		local description = Instance.new("HumanoidDescription")
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig
	end

	ok, rig = pcall(function()
		local description = Instance.new("HumanoidDescription")
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig
	end

	SharedUtil.Warn(TAG, "No se pudo crear el rig R15 del NPC; se usa el modelo de respaldo")
	local model = Instance.new("Model")
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 5, 1)
	hrp.Color = Color3.fromRGB(200, 200, 200)
	hrp.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = hrp
	return model
end

-- Asigna el personaje al fighter y aplica sus Stats. El atributo KB_CharacterId es lo que
-- luego usa CombatService para resolver el MoveSet del actor (vale para Player y NPC).
-- La energia arranca llena cada ronda; a partir de ahi la gestiona CombatService.
local function applyCharacter(f)
	local model, hum = f.Model, f.Humanoid
	if not (model and hum) then
		return
	end
	local character = Characters.Get(f.CharacterId or Characters.PracticeId)
	f.CharacterId = character.Id
	f.WalkSpeed = character.Stats.WalkSpeed

	model:SetAttribute(Characters.Attribute, character.Id)
	model:SetAttribute("KB_MaxEnergy", character.Stats.MaxEnergy)
	model:SetAttribute("KB_Energy", character.Stats.MaxEnergy)

	hum.MaxHealth = character.Stats.MaxHealth
	hum.Health = character.Stats.MaxHealth
end

-- Devuelve true si el fighter quedo listo para la ronda
local function prepareFighter(f)
	if not f.SpawnPoint then
		return false
	end

	if f.Kind == "Player" then
		local player = f.Player
		if not (player and player.Parent == Players) then
			return false
		end
		resetCombatState(f)

		local character = loadCharacter(player)
		if not character then
			return false
		end
		local hum = character:WaitForChild("Humanoid", 5)
		local root = character:WaitForChild("HumanoidRootPart", 5)
		if not (hum and root and hum:IsA("Humanoid")) then
			return false
		end

		-- Sin ForceField: si no, TakeDamage no hace nada durante 10 s
		stripForceField(character)
		task.delay(0.2, function()
			if character.Parent then
				stripForceField(character)
			end
		end)

		f.Model = character
		f.Humanoid = hum
		f.Root = root
		applyCharacter(f)
		resetCombatState(f)
		placeModel(character, f.SpawnPoint)
		setMovementLocked(f, true)
		return true
	end

	-- NPC: siempre se reconstruye (un Humanoid muerto no se puede revivir)
	if f.Model then
		f.Model:Destroy()
		f.Model = nil
	end
	local model = buildNpcModel()
	model.Name = MatchConfig.PracticeNpcName

	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (hum and root) then
		model:Destroy()
		return false
	end
	hum.MaxHealth = MatchConfig.PracticeNpcHealth
	hum.Health = MatchConfig.PracticeNpcHealth
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	hum.HealthDisplayDistance = 50
	root.Anchored = true

	local arena = workspace:FindFirstChild("KombatBlox")
	arena = arena and arena:FindFirstChild("Arena")
	model.Parent = arena or workspace
	placeModel(model, f.SpawnPoint)

	f.Model = model
	f.Humanoid = hum
	f.Root = root
	applyCharacter(f)
	return true
end

------------------------------------------------------------------
-- Snapshot (contrato MatchStateChanged v1)
------------------------------------------------------------------
local function fighterSnapshot(f)
	return {
		Id = f.Id,
		Name = f.DisplayName,
		Model = f.Model,
		Player = f.Player,
		IsNPC = f.Kind == "NPC",
		RoundWins = f.RoundWins,
		CharacterId = f.CharacterId,   -- v1.4 (aditivo): personaje del fighter
	}
end

local function snapshot(m)
	if not m then
		-- Waiting. Contrato explicito: en Luau un campo nil NO existe, asi que los campos
		-- marcados como "ausente" no viajan por el Remote. El cliente trata la ausencia
		-- de Fighters.A / Fighters.B como "no hay partida".
		return {
			Version = SNAPSHOT_VERSION,
			MatchId = 0,
			Mode = nil,               -- ausente
			State = STATE.Waiting,
			Round = 0,
			RoundsToWin = MatchConfig.RoundsToWin,
			Fighters = {
				A = nil,              -- ausente
				B = nil,              -- ausente
			},
			StateEndsAt = nil,        -- ausente
			RoundResult = nil,        -- ausente
			MatchResult = nil,        -- ausente
		}
	end
	return {
		Version = SNAPSHOT_VERSION,
		MatchId = m.Id,
		Mode = m.Mode,
		State = m.State,
		Round = m.Round,
		RoundsToWin = MatchConfig.RoundsToWin,
		Fighters = {
			A = fighterSnapshot(m.Fighters.A),
			B = fighterSnapshot(m.Fighters.B),
		},
		StateEndsAt = m.StateEndsAt,
		RoundResult = if m.State == STATE.RoundEnd then m.RoundResult else nil,
		MatchResult = if m.State == STATE.MatchEnd then m.MatchResult else nil,
	}
end

local function broadcast(m)
	MatchStateChanged:FireAllClients(snapshot(m))
end

------------------------------------------------------------------
-- Ciclo de partida
------------------------------------------------------------------
-- Espera 'seconds' en tramos de <= 50 ms. Devuelve false en cuanto la partida deja de ser
-- la activa o hay forfeit (respuesta <= 50 ms durante las esperas; ver nota en loadCharacter).
local function step(m, seconds)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if match ~= m or m.Forfeit ~= nil then
			return false
		end
		task.wait(math.min(0.05, math.max(0, deadline - os.clock())))
	end
	return match == m and m.Forfeit == nil
end

local function createMatch()
	local players = Players:GetPlayers()
	if #players == 0 then
		return nil
	end
	if not (getSpawn("A") and getSpawn("B")) then
		if not warnedSpawns then
			warnedSpawns = true
			SharedUtil.Warn(TAG, "Faltan Workspace/KombatBlox/SpawnPoints/SpawnA y SpawnB. No se crean partidas.")
		end
		return nil
	end

	nextMatchId += 1
	-- El modo se FIJA aqui y no cambia durante la partida
	local mode = if #players >= 2 and not MatchConfig.ForcePractice then "PvP" else "Practice"

	local m = {
		Id = nextMatchId,
		Mode = mode,
		State = STATE.Waiting,
		Round = 0,
		Fighters = {},
		StateEndsAt = nil,
		RoundResult = nil,
		MatchResult = nil,
		ConsecutiveDraws = 0,
		KOPending = false,
		FirstKOAt = nil,
		Forfeit = nil,        -- Id del GANADOR por abandono
	}
	m.Fighters.A = newPlayerFighter("A", players[1])
	if mode == "PvP" then
		m.Fighters.B = newPlayerFighter("B", players[2])
	else
		m.Fighters.B = newNpcFighter("B")
	end
	return m
end

-- Fin de partida: NPC fuera; PRIMERO reaparecen los fighters muertos (esperando a su personaje)
-- y SOLO DESPUES se desbloquea a todos a la vez. Asi nunca hay un fighter libre mientras el otro
-- sigue sin personaje, y nadie queda congelado si no entra en la siguiente partida.
local function cleanupMatch(m)
	for _, f in eachFighter(m) do
		if f.Kind == "NPC" and f.Model then
			f.Model:Destroy()
			f.Model = nil
		end
	end
	if match == m then
		match = nil
	end

	-- 1) Reaparecer a los fighters muertos (sin respawn automatico)
	for _, f in eachFighter(m) do
		local player = f.Player
		if f.Kind == "Player" and player and player.Parent == Players then
			local character = player.Character
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			if not (hum and hum.Health > 0) then
				local newCharacter = loadCharacter(player)
				if newCharacter then
					f.Model = newCharacter
					f.Humanoid = newCharacter:FindFirstChildOfClass("Humanoid")
					f.Root = newCharacter:FindFirstChild("HumanoidRootPart")
				end
			end
		end
	end

	-- 2) Desbloquear a todos a la vez
	for _, f in eachFighter(m) do
		setMovementLocked(f, false)
	end

	broadcast(nil)
	log("Waiting")
end

local function endMatch(m, reason, winnerId)
	m.State = STATE.MatchEnd
	m.KOPending = false
	m.MatchResult = { Reason = reason, WinnerId = winnerId }
	for _, f in eachFighter(m) do
		resetCombatState(f)
		setMovementLocked(f, true)
	end
	m.StateEndsAt = serverNow() + MatchConfig.MatchEndTime
	broadcast(m)
	log(("MATCH END -> %s (%s)"):format(winnerId or "DRAW", reason))

	task.wait(MatchConfig.MatchEndTime)
	cleanupMatch(m)
end

-- Salida por step() == false
local function abort(m)
	if m.Forfeit then
		endMatch(m, "Forfeit", m.Forfeit)
	else
		cleanupMatch(m)
	end
end

local function runMatch(m)
	log("Match created (id " .. m.Id .. ")")
	log("Mode: " .. m.Mode)

	while true do
		m.Round += 1

		---------------- COUNTDOWN ----------------
		m.State = STATE.Countdown
		m.RoundResult = nil
		m.KOPending = false
		m.FirstKOAt = nil

		for _, f in eachFighter(m) do
			if not prepareFighter(f) then
				if m.Forfeit == nil then
					m.Forfeit = otherId(f.Id)
				end
				return abort(m)
			end
		end
		if m.Forfeit then
			return abort(m)
		end

		m.StateEndsAt = serverNow() + MatchConfig.CountdownTime
		broadcast(m)
		log(("Round %d"):format(m.Round))
		log("Countdown")
		for i = MatchConfig.CountdownTime, 1, -1 do
			log(tostring(i))
			if not step(m, 1) then
				return abort(m)
			end
		end

		---------------- FIGHTING ----------------
		m.State = STATE.Fighting
		for _, f in eachFighter(m) do
			setMovementLocked(f, false)
		end
		m.StateEndsAt = serverNow() + MatchConfig.RoundTime   -- solo para dibujar
		local deadline = os.clock() + MatchConfig.RoundTime   -- el servidor decide con su propio reloj
		broadcast(m)
		log("FIGHTING")

		local A = m.Fighters.A
		local B = m.Fighters.B
		local result = nil
		while not result do
			if not step(m, 0.05) then
				return abort(m)
			end
			local deadA = isDead(A)
			local deadB = isDead(B)

			if m.FirstKOAt == nil and (deadA or deadB) then
				m.FirstKOAt = os.clock()
				m.KOPending = true     -- CanAct = false desde ya
				log("KO")
			end

			if m.FirstKOAt then
				if (deadA and deadB) or os.clock() - m.FirstKOAt >= MatchConfig.DoubleKOWindow then
					if deadA and deadB then
						result = { Reason = "DoubleKO" }
					elseif deadA then
						result = { Reason = "KO", WinnerId = "B" }
					else
						result = { Reason = "KO", WinnerId = "A" }
					end
				end
			elseif os.clock() >= deadline then
				log("TIME")
				local pa = healthPct(A)
				local pb = healthPct(B)
				if math.abs(pa - pb) < 1e-6 then
					result = { Reason = "Draw" }
				elseif pa > pb then
					result = { Reason = "Time", WinnerId = "A" }
				else
					result = { Reason = "Time", WinnerId = "B" }
				end
			end
		end

		---------------- ROUND END ----------------
		-- Primero el estado: CanDealDamage / CanReceiveDamage pasan a false al instante
		m.State = STATE.RoundEnd
		m.KOPending = false
		m.RoundResult = result
		for _, f in eachFighter(m) do
			resetCombatState(f)
			setMovementLocked(f, true)
		end

		if result.WinnerId then
			m.Fighters[result.WinnerId].RoundWins += 1
			m.ConsecutiveDraws = 0
			log(("Round %d -> %s (%s)"):format(m.Round, result.WinnerId, result.Reason))
		else
			m.ConsecutiveDraws += 1
			log(("Round %d -> DRAW (%s)"):format(m.Round, result.Reason))
		end
		log(("Score: A %d - %d B"):format(A.RoundWins, B.RoundWins))

		m.StateEndsAt = serverNow() + MatchConfig.RoundEndTime
		broadcast(m)
		if not step(m, MatchConfig.RoundEndTime) then
			return abort(m)
		end

		---------------- ¿FIN DE PARTIDA? ----------------
		for _, f in eachFighter(m) do
			if f.RoundWins >= MatchConfig.RoundsToWin then
				return endMatch(m, "Rounds", f.Id)
			end
		end
		if m.ConsecutiveDraws >= MatchConfig.MaxConsecutiveDraws then
			return endMatch(m, "DrawLimit", nil)
		end
	end
end

------------------------------------------------------------------
-- Respawn de jugadores que NO son fighters (CharacterAutoLoads = false)
------------------------------------------------------------------
local function watchPlayer(player)
	player.CharacterAdded:Connect(function(character)
		local hum = character:WaitForChild("Humanoid", 5)
		if not (hum and hum:IsA("Humanoid")) then
			return
		end
		hum.Died:Connect(function()
			-- Los fighters reaparecen en el siguiente Countdown (o en cleanupMatch), nunca aqui
			if fighterByPlayer(player) then
				return
			end
			task.delay(Players.RespawnTime, function()
				if player.Parent == Players and not fighterByPlayer(player) and player.Character == character then
					loadCharacter(player)
				end
			end)
		end)
	end)

	-- Primer personaje (imprescindible para quien NO sea fighter: 3er jugador en PvP, o quien
	-- entre durante una partida). Si luego es fighter, prepareFighter espera a esta carga
	-- (cerrojo de loadCharacter) y hace la suya propia despues: nunca simultaneas.
	if not player.Character then
		task.spawn(loadCharacter, player)
	end
end

------------------------------------------------------------------
-- API para CombatService (siempre en servidor)
------------------------------------------------------------------
-- Nuevas acciones (M1, BlockStart, Dash). Fuera de partida: libre.
-- Acepta un Player (jugador) o un Model (NPC). Fuera de partida: libre.
local function fighterByRef(ref)
	local f = fighterByPlayer(ref)
	if not f and typeof(ref) == "Instance" and ref:IsA("Model") then
		f = fighterByModel(ref)
	end
	return f
end

function MatchService.CanAct(ref)
	local f = fighterByRef(ref)
	if not f then
		return true
	end
	return match.State == STATE.Fighting and not match.KOPending
end

-- Golpes ya en su ventana activa: validos durante TODO Fighting (incluida la ventana de doble K.O.).
-- Desde RoundEnd: corte total e irreversible.
function MatchService.CanDealDamage(ref)
	local f = fighterByRef(ref)
	if not f then
		return true
	end
	return match.State == STATE.Fighting
end

function MatchService.CanReceiveDamage(model)
	local f = fighterByModel(model)
	if not f then
		return true
	end
	return match.State == STATE.Fighting
end

-- Autoridad de daño v1.1 (seguridad PvP): valida atacante Y victima por Model.
-- Solo hay daño si atacante y victima son los DOS Fighters (distintos) del match
-- actual y el combate esta en Fighting. Sirve para Player<->Player, Player<->NPC y
-- NPC<->Player. Fuera de match (combate libre en pruebas) devuelve true.
-- Rechaza por construccion a cualquier tercero (Player C, NPC ajeno, self-hit).
function MatchService.CanHit(attackerModel, victimModel)
	if not match then
		return true
	end
	local af = fighterByModel(attackerModel)
	local vf = fighterByModel(victimModel)
	if not (af and vf) then
		return false
	end
	if af.Id == vf.Id then
		return false
	end
	return match.State == STATE.Fighting
end

function MatchService.GetSnapshot()
	return snapshot(match)
end

------------------------------------------------------------------
-- Ciclo de vida
------------------------------------------------------------------
function MatchService:Init()
	-- FUENTE REAL en runtime: MatchService es el UNICO dueño del respawn.
	Players.CharacterAutoLoads = false
end

function MatchService:Start()
	local ok, service = pcall(Registry.Get, "CombatService")
	if ok then
		CombatService = service
	else
		SharedUtil.Warn(TAG, "CombatService no registrado: las rondas no podran limpiar estados de combate")
	end

	GetMatchState.OnServerInvoke = function()
		return snapshot(match)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		loading[player] = nil
		local f = fighterByPlayer(player)
		if f and match and match.State ~= STATE.MatchEnd and match.Forfeit == nil then
			match.Forfeit = otherId(f.Id)
			log("Forfeit: " .. f.DisplayName .. " abandono la partida")
		end
	end)

	broadcast(nil)
	log("Waiting")

	-- Bucle principal: una partida a la vez; si algo falla, se limpia y se crea otra.
	task.spawn(function()
		while true do
			if not match then
				local m = createMatch()
				if m then
					match = m
					local okRun, err = pcall(runMatch, m)
					if not okRun then
						SharedUtil.Warn(TAG, "Error en la partida: " .. tostring(err))
						pcall(cleanupMatch, m)
						if match == m then
							match = nil
						end
					end
				end
			end
			task.wait(1)
		end
	end)
end

return MatchService
