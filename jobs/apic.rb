require 'acirb'
require 'time'

apicuri = 'https://172.26.18.7'
username = 'admin'
password = 'cisco123'

login_time = Time.new.to_f
puts 'Connecting to APIC %s' % apicuri
rest = ACIrb::RestClient.new(url: apicuri, user: username,
                             password: password, format: 'json', debug: false)

health_points = []
(1..100).each do |i|
  health_points << { x: i, y: 0 }
end
last_health_x = health_points.last[:x]

thrupt_points = []
(1..100).each do |i|
  thrupt_points << { x: i, y: 0 }
end
last_thrupt_x = thrupt_points.last[:x]

last_endpoint_count = 0
last_actrlrule_count = 0
last_freeport_count = 0
last_tx = 0
last_rx = 0

def latest_endpoints(rest)
  cq = ACIrb::ClassQuery.new('fvCEp')
  cq.sort_order = 'fvCEp.modTs|desc'
  cq.page_size = '5'
  endpoints = rest.query(cq)

  endpoint_text = endpoints.map do |endpoint|
    { label: 'IP: %s MAC: %s' % [endpoint.ip, endpoint.mac], value: endpoint.modTs }
  end

  send_event('latest_endpoints', items: endpoint_text)
end

def update_actrlrule(rest, last_actrlrule_count)
  cq = ACIrb::ClassQuery.new('actrlRule')
  cq.subtree_include = 'count'
  actrlrule = rest.query(cq)
  if actrlrule
    count = actrlrule[0].count
    send_event('apic_actrlrule', current: count,
                                 last: last_actrlrule_count)
  end
  count
end

def update_endpointcount(rest, last_endpoint_count)
  cq = ACIrb::ClassQuery.new('fvCEp')
  cq.subtree_include = 'count'
  endpoints = rest.query(cq)
  if endpoints
    count = endpoints[0].count
    send_event('apic_endpoints', current: count,
                                 last: last_endpoint_count)
  end
  count
end

def update_freeports(rest, last_freeport_count)
  cq = ACIrb::ClassQuery.new('l1PhysIf')
  cq.subtree_prop_filter = 'eq(l1PhysIf.usage, "discovery")'
  cq.subtree_include = 'count'
  freeports = rest.query(cq)
  if freeports
    count = freeports[0].count
    send_event('apic_freeports', current: count,
                                 last: last_freeport_count)
  end
  count
end

def update_endpoint_chart(rest)
  cq = ACIrb::ClassQuery.new('fvCEp')
  cq.subtree_include = 'count'
  cq.prop_filter = 'wcard(fvCEp.lcC,"vmm")'
  vmm_endpoints = rest.query(cq)

  cq = ACIrb::ClassQuery.new('fvCEp')
  cq.subtree_include = 'count'
  all_endpoints = rest.query(cq)

  if vmm_endpoints && all_endpoints
    vmm_count = vmm_endpoints[0].count
    all_count = all_endpoints[0].count
    send_event('ep_chart', slices: [
      ['End Point Type', 'Hosts'],
      ['VMM', vmm_count.to_i],
      ['Bare Metal', all_count.to_i - vmm_count.to_i]
    ])
  end
end

def get_int_stats(rest)
  start = Time.new.to_f
  cq = ACIrb::ClassQuery.new('l1PhysIf')
  cq.subtree_include = 'stats'
  cq.subtree_class_filter = 'eqptEgrTotal5min,eqptIngrTotal5min'
  cq.prop_filter = 'eq(l1PhysIf.switchingSt,"enabled")'
  interfaces = rest.query(cq)
  puts '%d interfaces returned stats. %.2f seconds' % [interfaces.length, (Time.new.to_f - start)]
  interfaces
end

def update_unicast_per_second(last_tx, last_rx, interfaces)
  tx = 0
  rx = 0
  interfaces.each do |interface|
    begin
      interface.CDeqptEgrTotal5min.each do |egr|
        tx += egr.bytesRate.to_i
      end
      interface.CDeqptIngrTotal5min.each do |ingr|
        rx += ingr.bytesRate.to_i
      end
    rescue => e
      puts 'Exception %s' % e
    end
  end

  send_event('apic_packets_tx', current: tx, last: last_tx)
  send_event('apic_packets_rx', current: rx, last: last_rx)
  [tx, rx]
end

def update_thrupt(thrupt_points, last_x, interfaces)
  tx = 0
  rx = 0

  interfaces.each do |interface|
    begin
      interface.CDeqptEgrTotal5min.each do |egr|
        tx += egr.bytesRate.to_i
      end
      interface.CDeqptIngrTotal5min.each do |ingr|
        rx += ingr.bytesRate.to_i
      end
    rescue => e
      puts 'Exception %s' % e
    end
  end

  thrupt_points.shift
  last_x += 1
  thrupt_points << { x: last_x, y: (tx + rx) }
  send_event('apic_thrupt', points: thrupt_points)
  [last_x, thrupt_points]
end

def update_health(rest, points, last_x)
  dn = 'topology/health'
  health = rest.lookupByDn(dn)
  if health
    points.shift
    last_x += 1
    points << { x: last_x, y: health.cur.to_i }
    status = case health.cur.to_i
      when 90..100 
        'ok'
      when 75..89 
        'danger'
      else 
        'warning'
    end
    send_event('apic_health', points: points, status: status)
  end
  [last_x, points]
end

def update_unreachable_switch(rest)
  cq = ACIrb::ClassQuery.new('fabricNode')
  cq.prop_filter = 'and(eq(fabricNode.fabricSt,"inactive"),ne(fabricNode.role,"unsupported"),ne(fabricNode.role,"controller"))'
  cq.subtree_include = 'count'
  unreachable_switch = rest.query(cq)
  if unreachable_switch
    count = unreachable_switch[0].count
    status = case count.to_i
      when 0
        'ok'
      else 
        'warning'
    end
    send_event('apic_unreachable_switch', current: count, status: status)
  end
end

def update_controller_status(rest)
  cq = ACIrb::ClassQuery.new('infraWiNode')
  cq.prop_filter = 'wcard(infraWiNode.dn, "topology/pod-1/node-1/av")'
  controller_health = rest.query(cq)
  puts controller_health
  if controller_health
    send_event('apic_controllerhealth', current: 1, status: 'ok')
  end
end



scheduler = Rufus::Scheduler.start_new

scheduler.every '%ds' % (rest.refresh_time.to_i / 2) do
  # refresh the apic session at the half life of the reauthentication time
  puts 'Refreshing APIC session'
  begin
    rest.refresh_session
  rescue
    rest.authenticate
  end
  login_time = Time.new.to_f
end

#Thread.new do
#  loop do
#    puts 'Updating interface stats'
#    interfaces = get_int_stats(rest)
#    last_thrupt_x, thrupt_points = update_thrupt(thrupt_points,
#                                                 last_thrupt_x, interfaces)
#    last_tx, last_rx = update_unicast_per_second(last_tx, last_rx,
#                                                 interfaces)
#    sleep 3
#  end
#end

scheduler.every '3s' do
  Thread.new do
  	puts 'Updating interface stats'
    interfaces = get_int_stats(rest)
    last_thrupt_x, thrupt_points = update_thrupt(thrupt_points,
                                                 last_thrupt_x, interfaces)
    last_tx, last_rx = update_unicast_per_second(last_tx, last_rx,
                                                 interfaces)
  end
end                                              

scheduler.every '10s' do
  puts 'Updating health, endpoint count, unreachable nodes'
  last_health_x, health_points = update_health(rest, health_points,
                                               last_health_x)
  last_endpoint_count = update_endpointcount(rest, last_endpoint_count)
  update_unreachable_switch(rest)
end

scheduler.every '30s' do
  puts 'Updating access control rule count'
  last_actrlrule_count = update_actrlrule(rest, last_actrlrule_count)
end

scheduler.every '10s' do
  puts 'Updating count of end point types'

  update_endpoint_chart(rest)
  last_freeport_count = update_freeports(rest, last_freeport_count)
end

scheduler.every '60s' do
  puts 'Updating latest endpoints'
  latest_endpoints(rest)
end
