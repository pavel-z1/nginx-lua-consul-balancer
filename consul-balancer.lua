local http = require "resty.http"
local json = require "cjson"
local balancer = require "ngx.balancer"
local resty_chash = require "resty.chash"

local cache = ngx.shared.consul_cache
local sleep_server = "127.0.0.1:81"
-- General settings in seconds
local consul_timeout = 2 * 1000
local custom_healthcheck_timeout = 2 * 1000
local custom_healthcheck_threshold = 2
local _M = {}

function loadChashModule(name)
  if package.loaded[name] then
    return package.loaded[name]
  else
    package.loaded[name] = resty_chash:new({})
    return package.loaded[name]
  end
end

local function sort_table_keys(arg)
    local sorted_keys = {}
    for k in pairs(arg) do
        table.insert(sorted_keys, k)
    end
    table.sort(sorted_keys)
    return sorted_keys
end

 -- Generate a random list of numbers between 1-N
math.randomseed(os.time())
local function shuffle_numbers(n)
    local nums = {}
    for i = 1, n do
        nums[i] = i
    end
    for i = #nums, 2, -1 do
        local j = math.random(i)
        nums[i], nums[j] = nums[j], nums[i]
    end
    return nums
end

-- Run healthcheck for an individual service.
local function check_health(service, healthcheck_uri, address)
    local h = http.new()
    h:set_timeout(custom_healthcheck_timeout)
    local url = "https://" .. address .. healthcheck_uri
    local res, err = h:request_uri(url, {method = "GET", ssl_verify=false})

    local key = service .. "#" .. address
    local fail_count = cache:get(key)

    -- Healthcheck passed.
    if not err and res and res.status == 200 then
        if not fail_count then
            return address
        end
        if fail_count - 1 > 0 then
            cache:incr(key, -1)
            if cache:get(key .. "#failing") then
                return address
            end
            return nil
        end
        cache:delete(key)
        cache:delete(key .. "#failing")
        return address
    end

    if err == "timeout" then
        ngx.log(ngx.ERR, "healthcheck timeout for " .. service .. " on " .. address)
    elseif err ~= nil then
        ngx.log(ngx.ERR, "healthcheck failed for " .. service .. " on " .. address .. " - " .. err)
    else
        ngx.log(ngx.ERR, "healthcheck status code " .. res.status .. " for " .. service .. " on " .. address)
    end

    -- Healthcheck failed.
    if not fail_count then
        cache:set(key, 1)
        -- Set #failing flag which stands for failing_in_progress until completely failed.
        cache:set(key .. "#failing", true)
        return address
    end
    if fail_count < custom_healthcheck_threshold then
        cache:incr(key, 1)
    end
    if fail_count + 1 == custom_healthcheck_threshold then
        cache:set(key .. "#failing", false)
    end
    if cache:get(key .. "#failing") then
        return address
    end
    return nil
end

-- Check health of all instances of the service in parallel.
local function check_service(service, healthcheck_uri, addresses)
    -- Run healthchecks and filter out alive services.
    if healthcheck_uri ~= "" then
        local threads = {}
        for _, address in pairs(addresses) do
            table.insert(threads, ngx.thread.spawn(check_health, service, healthcheck_uri, address))
        end

        addresses = {}
        for _, thread in pairs(threads) do
            local ok, res = ngx.thread.wait(thread)
            if ok and res then
                table.insert(addresses, res)
            end
        end
    end

    -- Do not rewrite addresses if there is none.
    if #addresses == 0 then
        return
    end

    -- Retrieve previous addesses before we rewrite them.
    local prev_address_list = cache:get(service)

    -- Store alive addresses.
    cache:set(service, table.concat(addresses, " "))
end

-- Update all address in chash of the service in parallel.
local function update_chash(services)
    for service, _ in pairs(services) do
        local consul_service_instances_list = cache:get(service)

        if not consul_service_instances_list or consul_service_instances_list == "" then
            return
        end

        -- Prepare consistent Hash based on server addresses
        local nodes = {}
        local tmp_servers = {}
        local str_null = string.char(0)
        local nodes_count = 0
        for consul_service_instance in string.gmatch(consul_service_instances_list, "[^ ]+") do
            local id = string.gsub(consul_service_instance, ":", str_null)
            tmp_servers[id] = consul_service_instance
            nodes[id] = 1
            nodes_count = nodes_count + 1
        end

        -- Do not rewrite chash if there is none addresses for service.
        if nodes_count == 0 then
            return
        end

        package.loaded["servers_chash" .. string.gsub(service, "[-_:]", "")] = tmp_servers
        local chash_consul_service = loadChashModule("chash" .. string.gsub(service, "[-_:]", ""))
        chash_consul_service:reinit(nodes)
    end
end

local function refresh_consul(config)
    -- Get services from Consul.
    local h = http.new()
    h:set_timeout(consul_timeout)
    for service, params in pairs(config.services) do
        local custom_healthcheck = params.custom_healthcheck or ""
        local any_consul_state = params.any_consul_state or false
        local search_type = params.search_type or "service"
        local tags = params.tags or {}
        local addresses = {}
        for _, i in pairs(shuffle_numbers(#config.endpoints)) do
            local url = ""
            local service_tags = ""
            if search_type == "service" then
                if #tags > 0 then
                    url = config.endpoints[i] .. "/v1/health/service/" .. service .. "?tag=" .. tags[1]
                else
                    url = config.endpoints[i] .. "/v1/health/service/" .. service
                end
            elseif search_type == "query" then
                for _, tag in pairs(tags) do
                    service_tags = service_tags .. "_" .. tag
                end
                url = config.endpoints[i] .. "/v1/query/find_" .. service .. service_tags .. "/execute"
            end
            local res, err = h:request_uri(url, {
                method = "GET", query = "cached", headers = {["X-Consul-Token"] = token, ["Content-Type"] = "application/json", ["Cache-Control"] = "must-revalidate"},
            })
            if err then
                ngx.log(ngx.ERR, "Unable to connect to " .. url .. ": " .. err)
            elseif res and res.status ~= 200 then
                ngx.log(ngx.ERR, "Bad response from " .. url .. ": HTTP " .. res.status .. " " .. res.body)
            else
                local s = {}
                if search_type == "service" then
                    s = json.decode(res.body)
                elseif search_type == "query" then
                    s = json.decode(res.body).Nodes
                end
                for _, node in pairs(s) do
                    for _, check in pairs(node.Checks) do
                        if check.ServiceName == service and (any_consul_state or check.Status ~= "critical") then
                            table.insert(addresses, node.Node.Address .. ":" .. node.Service.Port)
                            break
                        end
                    end
                end
                break
            end
        end

        -- Check health of all instances of the service in parallel.
        ngx.thread.spawn(check_service, service, custom_healthcheck, addresses)
    end
end

-- Periodically refresh the list of service addresses from Consul.
function _M.refresh(premature, config)
    -- config.endpoints     The list of consul endpoints to call, e.g. {"http://localhost:8500"}
    -- config.token_func    (optional) A function to execute in order to get consul token
    -- config.interval      Service discovery refresh interval in seconds, the same as defined on ngx.timer.every(), normally 5s.
    -- config.services      Table of pairs "[consul_service]={custom_healthcheck="/healthcheck", any_consul_state=true, search_type="service", tags={"tag1", "tag2", "tag3"}}"
    --                      If custom_healthcheck is not empty it will do an additional HTTP healthcheck on a service.
    --                      If any_consul_state is true it will include all services rather than only non-critical ones.

    -- Run once per interval across all the workers. Employing some safety checks too.
    local lock = cache:get("consul_refresh_lock")
    local last_refresh = cache:get("consul_refresh_time")
    local max_lock_time = math.max(config.interval, 60)
    if lock then
        if last_refresh and os.time() - last_refresh > max_lock_time then
            ngx.log(ngx.ERR, "consul.refresh() was locked for longer than " .. max_lock_time .. "s. Ignoring lock...")
        else
            update_chash(config.services)
            return
        end
    end
    if last_refresh and os.time() - last_refresh < config.interval then
        update_chash(config.services)
        return
    end
    cache:set("consul_refresh_lock", true)

    local token = ""
    if config.token_func then
        token = config.token_func()
        if not token then
            ngx.log(ngx.ERR, "Consul token is missing 😡")
            cache:delete("consul_refresh_lock")
            return
        end
    end

    cache:set("consul_refresh_time", os.time())
    cache:delete("consul_refresh_lock")

    refresh_consul(config)
    update_chash(config.services)
    cache:set("consul_refresh_time", os.time())
    cache:delete("consul_refresh_lock")
end

-- Balance between upstream servers.
-- Try randomly 1 of the servers. If it fails, try from other unless we have only one.
function _M.balance(config)
    -- config.service          service name (default nil)
    -- config.balance_method   upstream backend balance method (default random) {random|hash}
    -- config.hash_key         hash key (applied only for hash balance method, default ngx.var.remote_addr)

    local balance_method = config.balance_method or "random"
    local hash_key = ngx.var.remote_addr
    if config.balance_method and config.balance_method == "hash" then
        hash_key = config.hash_key
    end

    local consul_service_instances_list = cache:get(config.service)
    if not consul_service_instances_list or consul_service_instances_list == "" then
        ngx.log(ngx.ERR, "Debug no Consul Instances for Service: " .. config.service)
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    -- Find previously failed backend if that's a case.
    local prev_backend = ""
    local use_sleep_server = false
    local fail_state = balancer.get_last_failure()
    local conn_try = {}
    if fail_state then
        --local upstream_addrs = split.split_upstream_var(ngx.var.upstream_addr) or {}
        --ngx.log(ngx.ERR, "Upstreams count: " .. table.concat(upstream_addrs))
        -- Need to catch the last address from "10.0.7.141:42014 : ", "10.0.7.141:42014, 10.0.7.140:42014 : " etc.
        _, _, prev_backend = ngx.var.upstream_addr:find("([%d%.]+:%d+) ")
        if prev_backend ~= sleep_server then
            ngx.ctx.prev_backend = prev_backend
        end
        ngx.log(ngx.ERR, "previous upstream " .. prev_backend .. " failed, trying another one...")
        
        if ngx.var.delayed_retry ~= "" then
            if not ngx.ctx.request_id then
                ngx.ctx.request_id = ngx.var.request_id
            end
            local key = config.service .. "#retry_num#" .. ngx.ctx.request_id
            conn_try = cache:get(key)
            if not conn_try then
                cache:set(key, 2, 120)
                conn_try = 2
            end
            cache:incr(key, 1)
            -- Sleep for 5s every 2 retries.
            if (conn_try - 1) % #ngx.ctx.initial_backend_servers == 0 and prev_backend ~= sleep_server then
                use_sleep_server = true
            end
        end
    end

    -- Choose proxy_pass backend.
    local backend = ""
    local backend_servers = {}
    if #consul_service_instances_list == 0 then
        --ngx.log(ngx.ERR, "No servers, used previous backend for service: " .. config.service)
        backend = ngx.ctx.prev_backend
    elseif balance_method == "hash" then
        local chash_consul_service = loadChashModule("chash" .. string.gsub(config.service, "[-_:]", ""))
        local chash_servers = package.loaded["servers_chash" .. string.gsub(config.service, "[-_:]", "")]
        local id = chash_consul_service:find(ngx.var.remote_addr)
        if not id then
            ngx.log(ngx.ERR, "Service: " .. config.service .. ", Consul Instances exist but chash not yet initiated")
            return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
        end
        backend = chash_servers[id]
    elseif balance_method == "random" then
        for server in consul_service_instances_list:gmatch("[^ ]+") do
            table.insert(backend_servers, server)
        end
        local id = math.random(#backend_servers)
        backend = backend_servers[id]
    end

    -- Set proxy_pass backend.
    if use_sleep_server then
        backend = sleep_server
    end
    local host, port = string.match(backend, "^(.+):(%d+)$")


    -- This block will only trigger if ngx.ctx.retry is not true.
    -- We set this to true during the initial request so future
    -- requests within this context will not go down this path.
    if not ngx.ctx.retry then
        ngx.ctx.retry = true
        -- set up more tries using the length of the server list minus 1.
        for server in consul_service_instances_list:gmatch("[^ ]+") do
            table.insert(backend_servers, server)
        end
        ngx.ctx.initial_backend_servers = backend_servers
        local tries = #backend_servers*5
        --ok, err = balancer.set_more_tries(#servers - 1)
        ok, err = balancer.set_more_tries(tries)
        if not ok then
            ngx.log(ngx.ERR, "set_more_tries failed: ", err)
        end
    end

    ok, err = balancer.set_current_peer(host, port)
    if not ok then
        ngx.log(ngx.ERR, "set_current_peer failed: ", err)
        return ngx.exit(500)
    end
end

-- Describe service for the status output
local function describe_service(service)
    local address_list = ""
    local service_list = cache:get(service)
    if not service_list or service_list == "" then
        return nil
    end

    for server in string.gmatch(service_list, "[^ ]+") do
        --local key = service .. "#" .. server .. "#throttling"
        --local weight = service_warmup_period
        --local ttl = cache:ttl(key) or 0
        --if ttl > 0 then
        --    weight = weight - ttl
        --end
        --local pct = math.floor(weight * 100 / service_warmup_period)
        --if pct == 100 then
        --    pct = ""
        --else
        --    pct = "[" .. pct .. "%]"
        --end
        address_list = address_list .. server .. " "
    end
    return address_list
end

local function if_then_else(arg, res_true, res_false)
    if arg then
        return res_true
    end
    return res_false
end

-- Output Consul SD status
function _M.print_status(config)
    -- config.is_debug     Enable debug mode to print all keys from lua dict.
    -- config.services     Table of pairs where keys are service names. Same as passing one to consul.refresh()

    local consul_refresh_time = cache:get("consul_refresh_time")
    ngx.say("* Consul SD")
    ngx.say(string.format("  %-26s", "Last refresh time:") .. if_then_else(consul_refresh_time, os.date("%c", consul_refresh_time), "?"))
    for _, service in pairs(sort_table_keys(config.services)) do
        local addresses = describe_service(service)
        ngx.say(string.format("  %-26s", service .. ":") .. if_then_else(addresses, addresses, "?"))
    end
    ngx.say("")

    if config.is_debug then
        ngx.say("-- LUA dict keys --")
        local keys = cache:get_keys()
        for _, k in pairs(keys) do
           ngx.say(k .. " | " .. tostring(cache:get(k)))
        end
    end
end

return _M
