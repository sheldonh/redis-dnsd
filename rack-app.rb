#!/usr/bin/env ruby

require 'rubygems'
require 'rack'
require 'json'
require 'etcd'
require 'thread'

class Dnsd
  def initialize(etcd_peers: ['http://127.0.0.1:4001'], publish_domain: 'docker', ttl: 30, ttl_refresh: 15)
    @peers, @domain = etcd_peers, publish_domain
    @ttl, @ttl_refresh = 30, 15
    @records = {}
    @mutex = Mutex.new
  end

  def update(master: nil, slaves: [])
    records = {}
    shortname = master.split('.').first
    $stderr.puts "getting #{skydns_path(master)}"
    srv = get(skydns_path(master)).node.value
    records["master.#{@domain}"] = srv

    slaves.each do |slave|
      shortname = slave.split('.').first
      $stderr.puts "getting #{skydns_path(slave)}"
      srv = get(skydns_path(slave)).node.value
      records["#{shortname}.slaves.#{@domain}"] = srv
    end

    @mutex.synchronize do
      stop_refresh_thread
      @records = records # stale slaves will time out
      publish!
      start_refresh_thread
    end
  end

  private

    def start_refresh_thread
      @refresh_thread ||= Thread.new do
        loop do
          sleep(@ttl_refresh)
          @mutex.synchronize do
            refresh!
          end
        end
      end
    end

    def stop_refresh_thread
      if @refresh_thread
        @refresh_thread.kill.join
        @refresh_thread = nil
      end
    end

    def publish!
      @records.each do |hostname, srv|
        $stderr.puts "setting #{hostname} to #{srv}"
        set(skydns_path(hostname), value: srv, ttl: @ttl)
      end
    end

    def refresh!
      @records.each do |hostname, srv|
        $stderr.puts "refreshing #{hostname} to #{srv}"
        set(skydns_path(hostname), value: srv, ttl: @ttl)
      end
    end

    def get(*args)
      etcd_operation(:get, *args)
    end

    def set(*args)
      etcd_operation(:set, *args)
    end

    def etcd_operation(op, *args)
      tries = 0
      begin
        etcd.send(op, *args)
      rescue Exception
        if (tries += 1) < 4
          disconnect
          sleep 1
          retry
        end
        raise
      end
    end

    def disconnect
      @etcd = nil
    end

    def etcd
      @etcd ||= Etcd.client(@peers.sample)
    end

    def skydns_path(dns)
      "/skydns/#{path(dns)}"
    end

    def path(dns)
      dns.split(".").reverse.join("/")
    end

end

class DnsdRackApp
  def initialize(dnsd: nil)
    @dnsd = dnsd
  end

  def call(env)
    req = Rack::Request.new(env)
    if req.path == "/dns"
      if req.put?
        master(req)
      else
        [405, {'Content-Type' => 'text/plain'}, ["Method Not Allowed\n"]]
      end
    else
      [404, {'Content-Type' => 'text/plain'}, ["Object Not Found\n"]]
    end
  end

  private

    def master(req)
      begin
        json = req.body.read
        body = JSON.parse(json)
        master = body["master"]["address"]
        slaves = body["slaves"].inject([]) { |acc, s| acc << s["address"] }
        begin
          @dnsd.update(master: master, slaves: slaves)
          [200, {'Content-Type' => 'text/plain'}, ["OK\n"]]
        rescue Exception => e
          $stderr.puts "#{e.class}: #{e.message}\n\t#{e.backtrace.join("\n\t")}"
          [500, {'Content-Type' => 'text/plain'}, ["#{e.class}: #{e.message}\n"]]
        end
      rescue Exception => e
        $stderr.puts "#{e.class}: #{e.message}\n\t#{e.backtrace.join("\n\t")}"
        [400, {'Content-Type' => 'text/plain'}, ["#{e.class}: #{e.message}\n"]]
      end
    end
end

def get_peers_from_env(env)
  if env['ETCD_PEERS']
    env['ETCD_PEERS'].split.map do |peer|
      p = peer.dup
      peer.gsub!(/http(s?):\/\//, '')
      if $1 == "s"
        $logger.fatal "etcd SSL not currently supported"
        exit(1)
      end
      peer.gsub!(/\/.*/, '')
      host, port = peer.split(':')
      {host: host, port: port}
    end
  else
    [ {host: env['ETCD_PORT_4001_TCP_ADDR'], port: env['ETCD_PORT_4001_TCP_PORT']} ]
  end
end

etcd_peers = get_peers_from_env(ENV)
publish_domain = ENV['PUBLISH_DOMAIN'] || 'docker'
ttl = ENV['TTL'] || 30
ttl_refresh = ENV['TTL_REFRESH'] || 15

dnsd = Dnsd.new(etcd_peers: etcd_peers, publish_domain: publish_domain, ttl: ttl, ttl_refresh: ttl_refresh)
app = DnsdRackApp.new(dnsd: dnsd)
Rack::Handler::WEBrick.run(app, :Port => 8080)
