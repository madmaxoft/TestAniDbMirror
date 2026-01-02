-- main.lua

--[[
AniDbMirror Lua client main loop.
Queries the AniDbMirror CnC server for anime details to download, then downloads them
and commits them back to the CnC server.

--]]





local socket = require("socket")
local sockethttp = require("ssl.https")
local ltn12 = require("ltn12")
local expat = require("lxp")
local lom = require("lxp.lom")
local lfs = require("lfs")
local zlib = require("zlib")




-- Read the config from the environment:
local gClientName   = assert(os.getenv("LocalAniDbMirror_ClientName"),   "Missing ClientName")
local gClientSecret = assert(os.getenv("LocalAniDbMirror_ClientSecret"), "Missing ClientSecret")
local gApiServer    = assert(os.getenv("LocalAniDbMirror_ApiServer"),    "Missing ApiServer")
assert(gClientName ~= "",   "Empty ClientName")
assert(gClientSecret ~= "", "Empty ClientSecret")
assert(gApiServer ~= "",    "Empty ApiServer")






--- Log a message with timestamp
local function log(aMsg, ...)
	local msg = string.format(aMsg, ...)
	print(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
end





------------------------------------------------------------------------------ utils:
--- Base64-encode a string
local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64Encode(aData)
	assert(type(aData) == "string")

	local result = {}
	local padding = 0

	for i = 1, #aData, 3 do
		local a, b1, c = aData:byte(i, i + 2)
		if not(b1) then
			b1 = 0
			padding = padding + 1
		end
		if not(c) then
			c = 0
			padding = padding + 1
		end
		local n = a * 65536 + b1 * 256 + c
		local c1 = math.floor(n / 262144) % 64 + 1
		local c2 = math.floor(n / 4096) % 64 + 1
		local c3 = math.floor(n / 64) % 64 + 1
		local c4 = n % 64 + 1
		result[#result + 1] = b:sub(c1, c1) .. b:sub(c2, c2) .. b:sub(c3, c3) .. b:sub(c4, c4)
	end

	if (padding > 0) then
		result[#result] = result[#result]:sub(1, 4 - padding) .. string.rep("=", padding)
	end

	return table.concat(result)
end





--- URL-encodes the specified string
local function urlEncode(aStr)
	assert(type(aStr) == "string")

	return (aStr:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end





---------------------------------------------------------------------------- http:
--- Parses the given string into a Lua table
-- Returns nil and error message on failure
local function parseLuaTable(aBody)
	local chunk, err = loadstring("return " .. aBody)
	if not(chunk) then
		return nil, "invalid lua response: " .. tostring(err)
	end

	local ok, result = pcall(chunk)
	if not(ok) then
		return nil, "lua eval failed: " .. tostring(result)
	end

	log("parseLuaTable: parsed into type %s", type(result))
	return result
end





--- Sends a GET request to the CnC server
-- Returns the response as a Lua table, or nil and message on failure
local function httpGet(aUrl)
	local responseChunks = {}
	local ok, code = sockethttp.request(
	{
		url = aUrl,
		sink = ltn12.sink.table(responseChunks),
		headers =
		{
			["Client-Name"] = gClientName,
			["Client-Secret"] = gClientSecret,
		},
	})
	if (not(ok) or (code ~= 200)) then
		if (code == 401) then
			local body = table.concat(responseChunks)
			log("Unauthorized, response: %s %s", body:sub(1, 3), body:sub(4))
		end
		return nil, string.format("http GET of %s failed: code %s", aUrl, tostring(code))
	end
	local body = table.concat(responseChunks)
	log("http GET of %s succeeded, got %d bytes in response.", aUrl, #body)
	return parseLuaTable(body)
end





--- Sends a GET request to the CnC server
-- Returns the response as a Lua table, or nil and message on failure
local function httpPost(aUrl, aBody)
	local responseChunks = {}
	local ok, code = sockethttp.request(
	{
		url = aUrl,
		method = "POST",
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
			["Content-Length"] = tostring(#aBody),
			["Client-Name"] = gClientName,
			["Client-Secret"] = gClientSecret,
		},
		source = ltn12.source.string(aBody),
		sink = ltn12.sink.table(responseChunks),
	})
	if (not(ok) or (code ~= 200)) then
		return nil, string.format("http POST to %s failed: code %s", aUrl, tostring(code))
	end
	local body = table.concat(responseChunks)
	log("http POST to %s succeeded, got %d bytes in response.", aUrl, #body)
	return parseLuaTable(body)
end





-------------------------------------------------------------------------------- main:

--- Check server status
-- Returns true if the server replies as expected
local function checkServer()
	-- Check if this is an API server at all:
	local resp, err = httpGet(gApiServer .. "/status")
	if not resp then
		return nil, err
	end
	if ((type(resp) ~= "table") or not(resp.ok)) then
		return nil, "invalid status response"
	end
	log("server status OK")

	-- Check auth:
	resp, err = httpGet(gApiServer .. "/statusAuth")
	if not resp then
		return nil, err
	end
	if ((type(resp) ~= "table") or not(resp.ok)) then
		return nil, "invalid statusAuth response"
	end
	log("server statusAuth OK")
	return true
end





--- Request a single work item
-- Returns the lua table returned from the API call
local function requestWork()
	return httpPost(gApiServer .. "/reserve", "")
end





--- Notifies the CnC server that we cannot complete this piece of work, let someone else handle it
local function abortWork(aId)
	assert(tonumber(aId))

	local body = "id=" .. tostring(aId)
	return httpPost(gApiServer .. "/giveBack", body)
end





--- Commit work result
local function commitWork(aId, aResult)
	assert(tonumber(aId))
	assert(type(aResult) == "string")

	local body =
		"id=" .. tostring(aId) ..
		"&detailsBlobB64=" .. urlEncode(base64Encode(aResult))
	return httpPost(gApiServer .. "/submit", body)
end





--- Fetches AniDB XML for the specified aId
-- If the response is compressed, decompresses it.
-- Also stores the received data into a file, no matter what is received
local function fetchAniDbXml(aId)
	assert(tonumber(aId))

	-- Pause for a while not to overload the server:
	socket.sleep(0.5)

	local url = "http://api.anidb.net:9001/httpapi?client=localanidbmirror&clientver=3&protover=1&request=anime&aid=" .. aId
	local response = {}
	local ok, code, headers = sockethttp.request{
		url = url,
		sink = ltn12.sink.table(response),
		headers = {
			["User-Agent"] = "LocalAniDbMirror/1",
		},
	}
	if (not(ok) or (code ~= 200)) then
		return nil, "HTTP request failed: " .. tostring(code)
	end
	response = table.concat(response)

	-- Decompress if the response is compressed:
	if (response:sub(1,2) == "\031\139") then
		if (zlib._VERSION:match("lzlib")) then
			response = zlib.inflate(response)
		elseif (zlib._VERSION:match("lua%-zlib")) then
			response = zlib.inflate()(response)
		else
			error("Unknown ZLIB version, was expecting lua-zlib or lzlib")
		end
	end

	return response
end





--- Processes a single aId piece
-- Returns the work to be committed to the CnC server, or nil and error message
-- If the rate-limit is reached, exits the whole process
local function processWork(aId)
	assert(tonumber(aId))

	local resp, msg = fetchAniDbXml(aId)
	if not(resp) then
		return nil, "Failed to fetch AniDb XML: " .. tostring(msg)
	end

	-- Assume that big responses are valid anime details:
	if (#resp > 1000) then
		return resp
	end

	-- For smaller responses, parse and check if it is an error:
	local parsedLom = lom.parse(resp)
	if (
		parsedLom and
		(parsedLom.tag == "error") and
		((parsedLom.attr or {}).code == "500")
	) then
		log("API returned rate-limit response for aid " .. aId .. ", exitting")
		abortWork(aId)
		os.exit(0)
	end

	-- Not an error, commit it:
	return resp
end





--- Main work loop
log("Starting LocalAniDbMirror client")

log("ClientName length: %d", #gClientName)
log("ClientSecret length: %d", #gClientSecret)
log("ApiServer length: %d", #gApiServer)

lfs.mkdir("output")
local ok, err = checkServer()
if not ok then
	error("Server check failed: " .. tostring(err))
end
log("Server verified")

while (true) do
	local resp, err = requestWork()
	if not(resp) then
		log("reserve failed: \"%s\"", tostring(err))
		os.exit(0)
	end

	if not(resp.ok) then
		log("no work available")
		os.exit(0)
	end

	local id = resp.id
	log("Reserved id %s", tostring(id))

	local result, msg = processWork(id)
	if not(result) then
		log("processing failed: \"%s\"", tostring(msg))
		os.exit(1)
	end

	-- Save to file:
	local f = assert(io.open("output/%d.xml", "wb"))
	f:write(result)
	f:close()

	local commitResp, commitErr = commitWork(id, result)
	if not(commitResp) then
		log("commit failed: \"%s\"", tostring(commitErr))
	elseif not(commitResp.ok) then
		log("commit rejected: \"%s\"", tostring(commitResp.error))
	else
		log("Committed id %s", tostring(id))
	end

	::continue::
end
