# lua-MultiRequests
[![Build Status](https://travis-ci.org/moteus/lua-MultiRequests.svg?branch=master)](https://travis-ci.org/moteus/lua-MultiRequests)
[![License](http://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

## Make multiple requests from different coroutines in parallel

This module uses cURL library to makes all requests.

### Usage
```Lua
local mrequest = MultiRequests.new()

-- start coroutine
mrequest:add_worker(function(requester)
  for i, url in ipairs(urls) do
    local response, err = requester:send_request{url = url}
    if response then
      print(url, response.code, response.content)
    else
      print(url, err)
    end
  end
end)

mrequest:run()
```
