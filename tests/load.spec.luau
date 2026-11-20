local Roblox = require('./roblox')
local Test = require('./test')

local test, expect = Test.test, Test.expect
local folder, module = Roblox.folder, Roblox.module

test('loadChildren requires direct child ModuleScripts sorted by name', function()
	local parent = folder('Services', {
		module('B', { name = 'B' }),
		Roblox.instance('Part', 'Part'),
		folder('Nested', { module('C', { name = 'C' }) }),
		module('A', { name = 'A' }),
	})

	local modules, errors = Roblox.new().Bootstrapper.loadChildren(parent)
	expect(modules).toEqual({ { name = 'A' }, { name = 'B' } })
	expect(errors).toBe(nil)
end)

test('loadDescendants sorts by name across folders, then by full name', function()
	local parent = folder('Root', {
		folder('Z', { module('Shared', { name = 'Z.Shared' }) }),
		folder('Y', { module('Shared', { name = 'Y.Shared' }), module('A', { name = 'Y.A' }) }),
	})

	local modules = Roblox.new().Bootstrapper.loadDescendants(parent)
	expect(modules).toEqual({ { name = 'Y.A' }, { name = 'Y.Shared' }, { name = 'Z.Shared' } })
end)

test('byName filters modules by a name pattern', function()
	local parent = folder('Server', {
		module('DataService', { name = 'DataService' }),
		module('DataController', { name = 'DataController' }),
	})

	local Bootstrapper = Roblox.new().Bootstrapper
	local modules = Bootstrapper.loadChildren(parent, Bootstrapper.byName('Service$'))
	expect(modules).toEqual({ { name = 'DataService' } })
end)

test('load keeps the given order, expands folders and skips duplicates', function()
	local loaded = { name = 'Loaded' }
	local moduleA = module('A', { name = 'A' })
	local moduleC = module('C', { name = 'C' })
	local group = folder('Group', { module('B', { name = 'B' }), moduleA })

	local modules = Roblox.new().Bootstrapper.load({ moduleC, group, loaded, moduleC, moduleA, loaded })
	expect(modules).toEqual({ { name = 'C' }, { name = 'A' }, { name = 'B' }, loaded })
	expect(modules[4]).toBe(loaded)
end)

test('load applies the predicate to ModuleScripts but not to loaded modules', function()
	local loaded = { name = 'Loaded' }
	local group = folder('Group', { module('Skipped', {}), module('DataService', { name = 'DataService' }) })

	local Bootstrapper = Roblox.new().Bootstrapper
	local modules = Bootstrapper.load({ module('Other', {}), group, loaded }, Bootstrapper.byName('Service$'))
	expect(modules).toEqual({ { name = 'DataService' }, loaded })
end)

test('load skips modules that fail and reports them by full name', function()
	local group = folder('Group', {
		module('Broken', function()
			error('broken module', 0)
		end),
		module('Good', { name = 'Good' }),
		module('Number', 5),
	})

	local roblox = Roblox.new()
	local modules, errors = roblox.Bootstrapper.load({ group, 'Path.To.Module' })
	expect(modules).toEqual({ { name = 'Good' } })
	expect(errors).toEqual({
		['Group.Broken'] = 'broken module',
		['Group.Number'] = 'Module must return a table; got number',
		UnknownModule = "Expected a ModuleScript, Folder or loaded module; got string 'Path.To.Module'",
	})
	expect(#roblox.errors).toBe(3)
	expect(roblox.errors[1]).toMatch("%[Bootstrapper%] Failed to load 'Group.Broken':\n    broken module")
end)

test('errors with the same name get a numbered key', function()
	local _, errors = Roblox.new().Bootstrapper.load({ 1, 2 })
	expect(errors and errors.UnknownModule).toMatch('got number')
	expect(errors and errors['UnknownModule (2)']).toMatch('got number')
end)

test('loaded modules can be passed back in', function()
	local Bootstrapper = Roblox.new().Bootstrapper
	local modules = Bootstrapper.load(Bootstrapper.load({ module('A', { name = 'A' }) }))
	expect(modules).toEqual({ { name = 'A' } })
end)
