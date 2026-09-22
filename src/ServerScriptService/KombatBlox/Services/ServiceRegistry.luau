--!strict
local ServiceRegistry = {}
local services: {[string]: any} = {}
local order: {string} = {}

function ServiceRegistry.Register(name: string, service: any)
	assert(services[name] == nil, "Servicio duplicado: " .. name)
	services[name] = service
	table.insert(order, name)
end

function ServiceRegistry.Get(name: string): any
	return assert(services[name], "Servicio no registrado: " .. name)
end

function ServiceRegistry.StartAll()
	for _, n in order do local s = services[n] if s.Init then s:Init() end end
	for _, n in order do local s = services[n] if s.Start then task.spawn(s.Start, s) end end
end

return ServiceRegistry
