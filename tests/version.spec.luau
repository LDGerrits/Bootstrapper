local fs = require('@lune/fs')
local serde = require('@lune/serde')

local Test = require('./test')

local test, expect = Test.test, Test.expect

test('the version matches in wally.toml, the source and the README', function()
	local version = serde.decode('toml', fs.readFile('wally.toml')).package.version
	expect(fs.readFile('src/init.luau'):match('^%-%-!strict\n%-%-v([%d%.]+)')).toBe(version)
	expect(fs.readFile('README.md'):match('ldgerrits/bootstrapper@([%d%.]+)')).toBe(version)
end)
