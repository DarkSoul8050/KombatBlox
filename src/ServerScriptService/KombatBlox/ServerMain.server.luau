--!strict
local root = script.Parent
local Registry = require(root.Services.ServiceRegistry)
Registry.Register("DataService",   require(root.Data.DataService))
Registry.Register("MatchService",  require(root.Match.MatchService))
Registry.Register("CombatService", require(root.Combat.CombatService))
Registry.StartAll()
print("[KombatBlox] Servidor iniciado")
