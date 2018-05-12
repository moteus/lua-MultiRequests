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

local cURL = require "cURL.safe"
local json = prequire "cjson.safe"
local ztimer = prequire 'lzmq.timer'

local M = {
  _NAME      = 'MultiRequests',
  _VERSION   = '0.1.0-dev',
  _LICENSE   = "MIT",
  _COPYRIGHT = "Copyright (c) 2018 Alexey Melnichuk",
}

-------------------------------------------------------------------
local CoSleep = {} if ztimer then
CoSleep.__index = CoSleep

local SLEEP = {}

CoSleep.SLEEP = SLEEP

function CoSleep.new()
  local self = setmetatable({}, CoSleep)

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
  self._workers = {}
  self._multi = cURL.multi()
  self._responses = {}
  self._handels = {}
  self._remain = 0
  self._error_handlers = {}
  self._sleep = CoSleep.new()

  return self
end

function MultiRequests:add_worker(fn, errf)
  local co = coroutine.create(fn)
  table.insert(self._workers, co)
  self._error_handlers[co] = errf
  return self
end

local function append_request(self, easy, co)
  local ok, err = self._multi:add_handle(easy)
  if not ok then
    return nil, err
  end

  self._remain = self._remain + 1

  local response = {_co = co, content = {}}
  self._responses[easy] = response

  easy:setopt_writefunction(table.insert, response.content)

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

local function proceed_next(self, co, response)
  local ok, easy = coroutine.resume(co, response)

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

local function proceed_response(self, easy, response)
  local co = response._co

  self._responses[easy] = nil
  self._remain          = self._remain - 1
  response._co          = nil
  response.url          = easy:getinfo_effective_url()
  response.code         = easy:getinfo_response_code()
  response.content      = table.concat(response.content)

  proceed_next(self, co, response)
end

function MultiRequests:send_request(request)
  local easy = table.remove(self._handels) or cURL.easy()

  easy:reset()

  local body
  if request.body then
    if type(request.body) == 'string' then
      body = request.body
    else
      assert(json, 'no json module loaded. Unsupported non string requst body')

      local err
      body, err = json.encode(request.body)
      if not body then
        return nil, err
      end
    end
  end

  local ok, err = easy:setopt{
    url            = request.url,
    timeout        = request.timeout,
    followlocation = request.followlocation,
    post           = request.post,
    httpheader     = request.headers,
    postfields     = body,
  }

  if not ok then
    return nil, err
  end

  local response = coroutine.yield(easy)

  table.insert(self._handels, easy)

  if response.error then
    return nil, response.error
  end

  return response
end

if ztimer then

function MultiRequests:sleep(ms)
  return self._sleep:sleep(ms)
end

end

function MultiRequests:run()
  while #self._workers > 0 do
    for i = #self._workers, 1, -1 do
      local co = self._workers[i]
      proceed_next(self, co, self)
    end

    while (self._remain > 0) or (not self._sleep:empty()) do
      if self._remain > 0 then
        local last = self._multi:perform()                    -- do some work
        if last < self._remain then                           -- we have done some tasks
          while true do                                       -- proceed results/errors
            local easy, ok, err = self._multi:info_read(true) -- get result and remove handle
            if easy == 0 then break end                       -- no more data avaliable for now

            local response = self._responses[easy]
            response.error = err
            proceed_response(self, easy, response)
          end
        end

        local timeout = self._sleep:interval()
        self._multi:wait(timeout)                             -- wait while libcurl do io select
      else
        local timeout = self._sleep:interval()
        if timeout then
          ztimer.sleep(timeout)
        end
      end

      while true do
        local co = self._sleep:get_expire()
        if not co then
          break
        end
        proceed_next(self, co)
      end
    end
  end
end

end
-------------------------------------------------------------------

M.new = MultiRequests.new

M.__MultiRequests = MultiRequests

return M