local MultiRequests = require "MultiRequests"

local function make_iterator(t)
  local generator = coroutine.wrap(function()
    for i, url in ipairs(t) do
      coroutine.yield(i, url)
    end
  end)

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

local iurls = make_iterator(urls)

local mrequest = MultiRequests.new()

for tid = 1, 2 do
  mrequest:add_worker(function(requester)
    for i, url in iurls() do
      local timeout = 1000 + 1000 * math.random(5)

      printf('[INFO][%d - %d] sleeping %d', tid, i, timeout)
      requester:sleep(timeout)
      printf('[INFO][%d - %d] wakeup', tid, i)

      local response, err = requester:send_request{url = url}
      if response then
        printf('[INFO][%d - %d] %s %s', tid, i, tostring(response.code), tostring(response.content))
      else
        printf('[ERROR][%d - %d] %s', tid, i, tostring(err))
      end
    end
  end, function(err)
    printf('[ERROR][%d] %s', tid, err)
  end)
end

mrequest:run()
