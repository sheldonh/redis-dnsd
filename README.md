# redis-dnsd

Takes a redis master/slave topology as the JSON body of an HTTP PUT, and sets up and maintains `master` and `slaves`
SRV records for that topology in SkyDNS.

It takes configuration from the following environment variables:

* `PUBLISH_DOMAIN` - The SkyDNS domain into which to publish `master` and `slaves` SRV records (default: `docker`).
* `TTL` - The TTL to publish records with (default: `30`).
* `TTL_REFRESH` - The frequency with which to refresh the TTL of published records (default: `15`).
* `ETCD_PEERS` - A whitespace-delimited list of one or more etcd peer URLs (default: `http://127.0.0.1:4001`).
* `ETCD_PORT_4001_TCP_ADDR` - The address of an etcd peer if `ETCD_PEERS` is not given (default: `127.0.0.1`).
* `ETCD_PORT_4001_TCP_PORT` - The port of an etcd peer if `ETCD_PEERS` is not given (default: `4001`).

On receipt of a master/slave topology, the following work is performed immediately for each redis instance in the topology:

* Find that instance's SRV record in etcd. For example, `node-1.redis-1.docker` would be looked up from `/skydns/docker/redis-1/node-1`.
* If the instance is the master, copy its SRV record as `master` in `PUBLISH_DOMAIN`. For example, if `PUBLISH_DOMAIN` is `example.com`
  it will be written to `/skydns/com/example/master`.
* If the instance is a slave, copy its SRV record to the same name in `slaves` in `PUBLISH_DOMAIN`.
  For example, if `PUBLISH_DOMAIN` is `example.com`, `node-2.redis-1.docker` will be written to `/skydns/com/example/slaves/node-2`.

Then, every `TTL_REFRESH` seconds, the TTL of the created keys is refreshed. The TTL refreshes continue until the next request
is received.

Note that `redis-dnsd` does not monitor the topology and does not implement automatic fail-over. It simply publishes the intended topology
in SkyDNS. The consumer of this service is expected to use something like `redis-dictator` to apply the topology to the redis instances
themselves.

## Usage

`rack-app.rb` takes no arguments and takes configuration from the environment variables described above. It listens for HTTP PUT to `/dns`.
It expects the body of the request to be a json representation of the desired redis topology (see example below).

The `address` of an instance may be name. In the future, support for IP addresses and ports may be added. But for now, only SRV
records are supported, coupling this software tightly to SkyDNS.

## Example

```
ruby rack-app.rb &

cat > topology.json <<EOF
{
  "master": {
    "address": "node-1.redis-1.docker"
  },
  "slaves": [
    {
      "address": "node-2.redis-1.docker"
    },
    {
      "address": "node-3.redis-1.docker"
    }
  ]
}
EOF

curl -XPUT -d @topology.json http://127.0.0.1:8080/master
```
