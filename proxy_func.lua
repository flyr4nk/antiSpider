require "ngx" --ngx库


local config = require "config"
local tools = require "tools"
local ck = require "resty.cookie"
local conn = require "redis_conn"
local cjson = require "cjson"
local checkState = require "check"['checkState']


function dealProxyPass(r, isServerError)
	if r then
		--关闭redis链接
		conn.close(r)
	end
	--如果服务器异常了，那就需要关闭state
	if isServerError then
		ngx.log(ngx.INFO, string.format("isServerError is true, deal proxy pass"))
		tools.forceCloseSystem()
	end
	
	local args = ngx.req.get_uri_args()
	local tdcheck = args['_tdcheck']
	--如果开启了check
	if tdcheck == '1' then
		jsonpStr = tools.jsonp('1','')
		tools.jsonpSay(jsonpStr)
		ngx.exit(ngx.HTTP_OK)
		return
	end

end

function erroResponse(r)
	if r then
		--关闭redis链接
		conn.close(r)
	end
	
	local args = ngx.req.get_uri_args()
	local tdcheck = args['_tdcheck']
	--如果开启了check
	if tdcheck == '1' then
		jsonpStr = tools.jsonp('0','')
		tools.jsonpSay(jsonpStr)
		ngx.exit(ngx.HTTP_OK)
		return
	end
	ngx.exit(400)
end


function deepCheckDeviceId(deviceId, aesKey, remoteIp, remoteAgent, randomSha256)
	
	
	local trueDeviceContent = tostring(tools.aes128Decrypt(deviceId, aesKey))
	
	ngx.log(ngx.INFO, string.format("deepCheck before, deviceId:%s, trueDeviceContent: %s", deviceId, trueDeviceContent))
	
	if not trueDeviceContent or trueRemoteLastIp == '' then
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId aes128Decrypt error, deviceId is %s, remoteIp %s",deviceId, remoteIp))
		return false, nil
	end
	

	--对加密的deviceid进行解密
	local didList = tools.split(trueDeviceContent, ',')
	local didIpAgent = didList[1] or ''
	local aesEncryptIp = didList[2] or ''
	local aesEncryptRandom = didList[3] or ''
	
	ngx.log(ngx.INFO, string.format("deepCheckDeviceId aes128Decrypt, trueDeviceContent：%s | didIpAgent:%s | aesEncryptIp: %s | aesEncryptRandom: %s", trueDeviceContent, didIpAgent, aesEncryptIp, aesEncryptRandom))
	
	--拿到用户加密时用的ip地址
	local trueRemoteLastIp = tools.aes128Decrypt(aesEncryptIp, config.globalIpAesKey)
	--如果ip解密失败
	if not trueRemoteLastIp or trueRemoteLastIp == '' then
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId aes128Decrypt trueRemoteLastIp error, trueDeviceContent: %s ", trueDeviceContent))
		return false, nil
	end
	

	--拿到用户加密时用的随机数
	local trueRandom = tools.aes128Decrypt(aesEncryptRandom, config.globalIpAesKey)
	--如果随机数解密失败
	if not trueRandom or trueRandom == '' then
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId aes128Decrypt trueRandom error, trueDeviceContent: %s ", trueDeviceContent))
		return false, nil
	end
	--将随机数转为整数
	local trueRandomNum = tonumber(trueRandom)
	--如果这个整数不在100万和1000万之间，则报错
	if not trueRandomNum or trueRandomNum < 1000000 or trueRandomNum > 10000000 then
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId aes128Decrypt trueRandom invalid, trueRandom: %s ", trueRandom))
		return false, nil
	end
	
	--判断这个随机数是不是和session的randomSha256匹配
	local didRandomSha256 = tools.sha256(trueRandomNum..config.md5Gap..config.sessionKey)
	if didRandomSha256 ~= randomSha256 then
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId didRandomSha256 !=  randomSha256 trueRandom: %s, sessionRandomSha256: %s ", trueRandom, randomSha256))
		return false, nil
	end
	
	
	
	local expectShaStr = tools.sha256(trueRemoteLastIp..config.md5Gap..remoteAgent)
	--检查ip地址是否合法
	if didIpAgent ~= expectShaStr then
		--记录错误
		local lastKeyState = tools.getLastKeyCookie() or 'not found k_st cookie'
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId verifyDeviceId IP and agent not valid, remote ip: %s || remote agent: %s", remoteIp,remoteAgent))
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId verifyDeviceId IP and agent not valid, client : %s || server : %s || aesClient: %s", didIpAgent, expectShaStr, deviceId))
		ngx.log(ngx.ERR, string.format("deepCheckDeviceId verifyDeviceId IP and agent not valid, last get key ip and timestamp: %s", lastKeyState))
		return false, nil
	end
	
	return true, nil

end

--代理函数
function doProxy()	 
	
	--检查状态
	local gateStateVal, aesKey, aesSecret, remoteAgent, noAgent = checkState()
	--如果没有Agent，报错
	if noAgent then
		return erroResponse()
	end
	--如果 gateStateVal 为0，表示关闭验证，直接pass
	if gateStateVal == '0' then
		ngx.log(ngx.ERR, string.format('gateStateVal eq 0, close system or in white ip list'))
		return dealProxyPass()
	end
	
	--定义变量
	local enterTime = tools.getNowTs()
	local remoteIp = tools.getRealIp()
	local remoteAgent = remoteAgent

	--判断sessioncookie是否有效
	local isValidCookie, err, randomSha256 = tools.verifySessionCookie()
	--出错直接放过
	if err then
		return dealProxyPass(nil, true)
	end
	if not isValidCookie then
		return erroResponse()
	end

	--判断deviceId是否有效
	local deviceId, err = tools.simpleVerifyDeviceId()
	if err then
		return dealProxyPass(nil, true)
	end			
	if not deviceId or  deviceId == '' then
		return erroResponse()
	end
	
	
	--缓存字典对象
	local cachDict = ngx.shared.cachDict
	
	--检查deviceId的值是否被篡改
	local ok, err = deepCheckDeviceId(deviceId, aesKey, remoteIp, remoteAgent, randomSha256)
	--如果deep检查key错误，则要进一步判断是否更改过key
	if not ok then
		local lastKey = cachDict:get(config.lastGlobalAesKey)
		--如果没有lastkey
		if lastKey == ngx.null or not lastKey or lastGlobalAesKey == '' then
			return erroResponse()
		else
			local ok, err = deepCheckDeviceId(deviceId, lastKey, remoteIp, remoteAgent, randomSha256)
			if not ok then
				ngx.log(ngx.ERR, string.format("deepCheckDeviceId twice still error, deviceid: %s, remoteIp:%s", deviceId, remoteIp))
				return erroResponse()
			end
		end
	end
	
	
	--判断此deviceid是否在本地的黑名单中
	local blackDict = ngx.shared.blackDict 
	local isBlack = blackDict:get(deviceId) or nil
	if isBlack then
		ngx.log(ngx.ERR, string.format("request in local black dict, deviceId %s, remoteIp:%s", deviceId, remoteIp))
		return erroResponse()
	end
	
	
	
	
	--下面进行redis连接后的检查
	local r, err = conn.conn(deviceId)
	if err then
		ngx.log(ngx.ERR, string.format("doProxy redis connect error %s", err))
		--如果连接reids出错
		return dealProxyPass(nil, true)
	end
	

	--检查此deviceid是否在黑名单中
	local blackKey = string.format('black_%s', deviceId)
	local isBlack = r:get(blackKey)
	--如果在黑名单中
	if isBlack ~= ngx.null and isBlack then
		ngx.log(ngx.ERR, string.format("request in blackList, deviceId %s, remoteIp:%s", deviceId, remoteIp))
		return erroResponse(r)
	end

	--检查此deviceid是否访问频率过快
	local didKey = string.format(config.didKey, deviceId)
	local dtsKey = string.format(config.dtsKey, deviceId)
	local dipKey = string.format(config.dipKey, remoteIp)
	
	--ngx.log(ngx.ERR,'********************************'..didKey)
	
	--获取上一次请求时间
	local didTs = r:get(dtsKey)
	
	--如果没有找到这个deviceid上次请求的时间,则全部新建
	if didTs == ngx.null or not didTs then
		r:set(dtsKey, enterTime) --设置上次时间戳
		r:del(didKey)			 --删除片的key
		r:lpush(didKey,1)		 --新增片
		
	else
		--如果存在上次请求
		r:set(dtsKey, enterTime)
		--如果上一次请求在10秒钟之内，最新片+1
		if enterTime - tonumber(didTs) <= config.freqSec then
			local newCount = r:lindex(didKey,0)
			--如果list不存在
			if newCount == ngx.null or not newCount then
				newCount = 0
				--将计数+1
				local count = newCount + 1
				r:lpush(didKey, count)
			else
				--如果list存在，则把最新片+1
				newCount = tonumber(newCount)
				--将计数+1
				local count = newCount + 1
				r:lset(didKey, 0, count)
			end
			
		else
			
			--如果上一次请求在10秒钟之外,新建一个片
			r:lpush(didKey,1)
			r:ltrim(didKey, 0, config.freqShard)
		end
	end

	--进行访问频率判断
	--获得最新的6片数据
	didCountList, err = r:lrange(didKey, 0, config.freqShard)
	if err then
		ngx.log(ngx.ERR, string.format("proxy_func r:lrange(didKey, 0, config.freqShard), error: %s", err))
		return dealProxyPass(nil, true)
	end
	
	tempSum = 0
	for i = 1, config.freqShard, 1 do
		--记录每个分片的求和
		tempSum = tempSum + tonumber(didCountList[i] or 0)
				
		--当满足规则时，表示请求过于频繁
		if config.freqRule[i] ~= -1 and  tempSum >= config.freqRule[i] then
			ngx.log(ngx.ERR, string.format("request too freqency, deviceId %s, rule: %s, remoteIp: %s", deviceId, i, remoteIp))
			--访问频繁，本地先做一个黑名单缓存
			local succ, err = blackDict:set(deviceId, '1', 60)
			if err then
				ngx.log(ngx.ERR, string.format("proxy_func blackDict:set, error: %s", err))
			end
			return erroResponse(r)
		end
	end

	--将此deviceid存入ipkey中,这里要用set的key，保证数组中唯一
	r:sadd(dipKey, deviceId)

	--更新redis的key的expire过期时间
	r:expire(dtsKey, 600)
	r:expire(didKey, 600)
	r:expire(dipKey, 3600)
	
	--执行proxy
	dealProxyPass(r)
	--记录时间，进行转发
	--如果超过1秒, 记录错误日志
	local dealTime = tools.getNowTs() - enterTime
	if dealTime > 0.5 then
		ngx.log(ngx.ERR, string.format("proxy deal too long : %s", dealTime))
	end

end

doProxy()
