# lua-consul-balancer

Consul balancer for Openresty/Nginx.

* consul-balancer.lua - a lua file ready to copy/paste
* lua-resty-balancer - git submodule from https://github.com/openresty/lua-resty-balancer
* nginx.conf - the minimal Nginx config as an example

## Features

* Discover services from one or multiple Consul endpoints and stores their addresses for load balancing
* Periodically refresh addresses
* By default it picks up only non-critical services based on the Consul native healthcheck
* Optionally, you can enable an additional custom healthcheck against the service URL or allow services in warning state
* Last address standing - in case no addresses are available from Consul you will still get the latest one
* Possibility to get consul instalces (services) via consul service or prepared query template (more detailes https://developer.hashicorp.com/consul/api-docs/query https://developer.hashicorp.com/consul/docs/services/discovery/dns-dynamic-lookups)
* Two upsream balance logic: roundrobin and consistent hash method
* Possibility to specify key for hash balanced method
* Bonus: extra logic to sleep for 5s every retries of all upstream backend servers on error if `set $delayed_retry 1;` is defined on nginx location

Traffic throttling from origin was removed as it could cause issue in case of usage prepared query template

## Description

You can configure service discovery refresh interval. There are also a couple of hardcoded settings in the lua file.

We are using this lua code at Quiq for 4 years or so and it is very fast with even 50 services in total
and multiple addresses per each one. It doesn't produce much load on Openresty/Nginx if any at all.

## Openresty required modules

* resty.http
* resty.chash
* cjson

Installation:

```
git submodule update --init
git submodule update --remote
cd lua-resty-balancer
make
```

First you need to run `make` from the  to generate the librestychash.so.
Then you need to configure the lua_package_path and lua_package_cpath directive
to add the path of your lua-resty-chash source tree to ngx_lua's LUA_PATH search
path, as in

```nginx
    # nginx.conf
    http {
        lua_package_path "/path/to/lua-resty-balancer/lib/?.lua;;";
        lua_package_cpath "/path/to/lua-resty-balancer/?.so;;";
        ...
    }
```

Ensure that the system account running your Nginx ''worker'' proceses have
enough permission to read the `.lua` and `.so` file.

## Consul prepared Geo-Failover query example

Consul prepared query template:
```template_from_service_with_tags.json
{
  "Name": "find_",
  "Template": {
    "Type": "name_prefix_match",
    "Regexp": "^find_([^_]+)(?:_)?([^_]+)?(?:_)?([^_]+)?(?:_)?([^_]+)?.*$",
    "RemoveEmptyTags": true
  },
  "Service": {
    "Service": "${match(1)}",
     "Tags": ["${match(2)}", "${match(3)}", "${match(4)}"],
    "Failover": {
      "NearestN": 2
    }
  }
}
```
Add query template to each Consul cluster:
```
curl --header "X-Consul-Token: $CONSUL_HTTP_TOKEN" --header "Content-Type: application/json" http://127.0.0.1:8500/v1/query --request POST --data @template_from_service_with_tags.json
```

Example query request for service with name service-name:
```
curl --header "X-Consul-Token: $CONSUL_HTTP_TOKEN" --header "Content-Type: application/json" 'http://127.0.0.1:8500/v1/query/find_service-name_tag1_tag2_tag3/execute'
```


## Test with docker

Assuming you have added certificates to the folder, updated nginx.conf according to your needs
you can run a test as follow:

    $ ls -la
    total 80
    -rw-r--r--  1 weber  staff   1830 Mar 22 16:38 bundle-crt.pem
    -rw-r--r--  1 weber  staff   3940 Mar 22 16:42 ca-certificates.crt
    -rw-r--r--  1 weber  staff  12459 Mar 22 15:20 consul-balancer.lua
    drwxr-xr-x 13 weber  staff    416 Mar 22 09:42 lua-resty-balancer
    -rw-r--r--  1 weber  staff   3243 Mar 22 16:38 key.pem
    -rw-r--r--  1 weber  staff   1956 Mar 22 15:21 nginx.conf
    $
    $ docker run --rm -d -p 443:443 -v $PWD:/usr/local/openresty/nginx/conf:ro quiq/openresty:1.21.4.1-alpine

    $ curl -k https://localhost/status
    * Consul SD
      Last refresh time:        Thu Aug  4 12:21:51 2022
      foobar-service:           10.0.7.71:8081
      another-service:          10.0.7.74:8082 10.0.7.75:8082[50%]

`quiq/openresty` is our docker image built with everything required and available from Docker Hub.
