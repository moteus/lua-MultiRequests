------------------------------------------------------------------
--
--  Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Copyright (C) 2018 Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Licensed according to the included 'LICENSE' document
--
--  This file is part of lua-MultiRequests library.
--
------------------------------------------------------------------

local function prequire(m)
  local ok, err = pcall(require, m)
  if not ok then return nil, err end
  return err
end

local cURL   = require  "cURL.safe"
local json   = prequire "cjson.safe"
local ztimer = prequire 'lzmq.timer'

local M = {
  _NAME      = 'MultiRequests',
  _VERSION   = '0.1.0-dev',
  _LICENSE   = "MIT",
  _COPYRIGHT = "Copyright (c) 2018 Alexey Melnichuk",
}

-------------------------------------------------------------------
local CoSleep = {} CoSleep.__index = CoSleep if ztimer then

local SLEEP = {}

CoSleep.SLEEP = SLEEP

function CoSleep.new(...)
  local self = setmetatable({}, CoSleep)
  return self:__init(...)
end

function CoSleep:__init()
  self._timers = setmetatable({}, {__mode = 'kv'})
  self._timeouts = {}

  return self
end

function CoSleep:sleep(timeout)
  local co = coroutine.running()

  local timer = self._timers[co] or ztimer.monotonic()

  self._timers[co] = timer
  self._timers[timer] = co

  timer:start(timeout)

  local i = 1
  while i <= #self._timeouts do
    local timer = self._timeouts[i]
    if timeout < timer:rest() then
      break
    end
    i = i + 1
  end

  table.insert(self._timeouts, i, timer)

  return coroutine.yield(SLEEP)
end

function CoSleep:interval()
  local timer = self._timeouts[1]
  if timer then
    return timer:rest()
  end
end

function CoSleep:empty()
  return not self._timeouts[1]
end

function CoSleep:get_expire()
  local timer = self._timeouts[1]
  if timer and timer:rest() == 0 then
    table.remove(self._timeouts, 1)
    return self._timers[timer], timer:stop()
  end
end

else -- ztimer does not avaliable

function CoSleep.new()
  local self = setmetatable({}, CoSleep)
  return self
end

function CoSleep:sleep()end

function CoSleep:interval()end

function CoSleep:empty() return true end

function CoSleep:get_expire() end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
local MultiRequests = {} do
MultiRequests.__index = MultiRequests

function MultiRequests.new(...)
  local self = setmetatable({}, MultiRequests)
  return self:__init(...)
end

function MultiRequests:__init()
  self._multi = cURL.multi()
  self._coros          = {} -- easy => co map
  self._handels        = {} -- easy cache
  self._sleep          = CoSleep.new() -- co sleep queue
  self._remain         = 0 -- number of requests in progress

  self._workers        = {}
  self._error_handlers = {}

  return self
end

function MultiRequests:add_worker(n, fn, errf)
  if type(n) ~= 'number' then
    fn, errf, n = n, fn, nil
  end
  for _ = 1, (n or 1) do
    local co = coroutine.create(fn)
    table.insert(self._workers, co)
    self._error_handlers[co] = errf
  end
  return self
end

local function append_request(self, easy, co)
  local ok, err = self._multi:add_handle(easy)
  if not ok then
    return nil, err
  end

  self._remain = self._remain + 1
  self._coros[easy] = co

  return self
end

local function remove_worker(self, co)
  for i, worker in ipairs(self._workers) do
    if worker == co then
      table.remove(self._workers, i)
      self._error_handlers[worker] = nil
      break
    end
  end
end

local function proceed_next(self, co, ok, err)
  local ok, easy = coroutine.resume(co, ok, err)

  if ok and easy then
    if easy ~= CoSleep.SLEEP then
      append_request(self, easy, co)
    end
    return
  end

  local errf = self._error_handlers[co]

  remove_worker(self, co)

  if easy and not ok then
    if errf then errf(easy) end
  end

  return ok, easy
end

local function proceed_response(self, easy, ok, err)
  local co = self._coros[easy]
  self._coros[easy] = nil
  self._remain      = self._remain - 1

  proceed_next(self, co, ok, err)
end

function MultiRequests:easy_perform(easy)
  return coroutine.yield(easy)
end

function MultiRequests:multi_perform(easy)
  -- if coro takes long time to complit.
  -- it has to call this function to allows libcurl do io
  -- e.g. remote side send SSL handshake and wait response.
  -- libcurl have to response to it in some time.
  self._multi:perform()
end

function MultiRequests:send_request(request)
  local easy = table.remove(self._handels) or cURL.easy()

  easy:reset()

  local opt = {}
  for name, param in pairs(request) do
    if name == 'body' then
      local body
      if type(param) == 'string' then
        body = param
      else
        assert(json, 'no json module loaded. Unsupported non string requst body')

        local err
        body, err = json.encode(param)
        if not body then
          return nil, err
        end
      end

      opt.postfields = body
    elseif name == 'method' then
      opt.customrequest = param
    elseif name == 'headers' then
      opt.httpheader = param
    else
      opt[name] = param
    end
  end

  local ok, err = easy:setopt(opt)

  if not ok then
    return nil, err
  end

  local content
  if not opt.writefunction then
    content = {}
    easy:setopt_writefunction(table.insert, content)
  end

  ok, err = self:easy_perform(easy)

  table.insert(self._handels, easy)

  if not ok then
    return nil, err
  end

  return {
    url     = easy:getinfo_effective_url();
    code    = easy:getinfo_response_code();
    content = content and table.concat(content);
  }
end

if ztimer then

function MultiRequests:sleep(ms)
  return self._sleep:sleep(ms)
end

end

local function check_sleeping(self)
  local n = 0

  while true do
    local co = self._sleep:get_expire()
    if not co then break end
    proceed_next(self, co)
    n = n + 1
  end

  return n
end

function MultiRequests:run()
  while #self._workers > 0 do
    for i = #self._workers, 1, -1 do
      local co = self._workers[i]
      proceed_next(self, co, self)
    end

    while (self._remain > 0) or (not self._sleep:empty()) do
      if self._remain > 0 then
        local last = self._multi:perform()
        while last < self._remain do
          local easy, ok, err = self._multi:info_read(true) -- get result and remove handle
          if easy == 0 then break end                       -- no more data avaliable for now
          proceed_response(self, easy, ok, err)
          last = self._multi:perform()
          if check_sleeping(self) > 0 then
            last = self._multi:perform()
          end
        end

        -- do not wait too long if there exists some active io
        self._multi:wait()
      else
        -- we can sleep as long as needed because we do not bother about any IO
        local timeout = self._sleep:interval()
        if timeout then
          ztimer.sleep(timeout)
        end
      end
  
      check_sleeping(self)
    end
  end
end

end
-------------------------------------------------------------------

M.new = MultiRequests.new

M.__MultiRequests = MultiRequests

return M