local fs = require('@lune/fs')
local process = require('@lune/process')

local Test = require('./test')

local files = fs.readDir('tests')
table.sort(files)
for _, file in files do
	if file:match('%.spec%.luau$') then
		require(`./{file:gsub('%.luau$', '')}`)
	end
end

process.exit(if Test.run() == 0 then 0 else 1)
