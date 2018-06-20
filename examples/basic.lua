-- package.path = '..\\src\\?.lua;' .. package.path

local MultiRequests = require "MultiRequests"

local generators = {
  ipairs = function(t)
    local generator = coroutine.wrap(function()
      for i, url in ipairs(t) do
        coroutine.yield(i, url)
      end
    end)

    return generator
  end;

  flines = function(fname)
    local f = assert(io.open(fname, 'r'))
    local generator = coroutine.wrap(function()
      local i = 0
      for url in f:lines() do
        i = i + 1
        coroutine.yield(i, url)
      end
      f:close()
    end)

    return generator
  end;
}

local function make_iterator(generator)
  return function()
    return function()
      local i, url
      if generator then
        i, url = generator()
        if not url then 
          generator = nil
        end
      end
      return i, url
    end
  end
end

local function printf(...)
  print(string.format(...))
end

local urls = {
  "http://httpbin.org/get?key=1",
  "http://httpbin.org/get?key=2",
  "http://httpbin.org/get?key=3",
  "http://httpbin.org/get?key=4",
}

local iurls = make_iterator(generators.ipairs(urls))

local mrequest = MultiRequests.new()

for tid = 1, 2 do
  mrequest:add_worker(function(requester)
    for i, url in iurls() do
      local timeout = 1000 + 1000 * math.random(5)
      printf('%s [INFO][%d - %d] sleeping %d', os.date('%H:%M:%S'), tid, i, timeout)
      requester:sleep(timeout)
      printf('%s [INFO][%d - %d] wakeup', os.date('%H:%M:%S'), tid, i)

      local response, err = requester:send_request{url = url}
      if response then
        printf('%s [INFO][%d - %d] %s %s', os.date('%H:%M:%S'), tid, i, tostring(response.code), tostring(response.content))
      else
        printf('%s [ERROR][%d - %d] %s', os.date('%H:%M:%S'), tid, i, tostring(err))
      end
    end
  end, function(err)
    printf('%s [ERROR][%d] %s', os.date('%H:%M:%S'), tid, err)
  end)
end

mrequest:run()