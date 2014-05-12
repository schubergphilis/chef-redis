def load_current_resource
  new_resource.user         new_resource.user     || node.redis.user
  new_resource.group        new_resource.group    || node.redis.group
  new_resource.log_file     new_resource.log_file || node.redis.config.logfile

  new_resource.state # Load attributes

  new_resource.redis_cluster_name new_resource.redis_cluster_name || node.redis.redis_cluster_name

  if new_resource.redis_cluster_name
    monitor_string = [get_cluster_master, new_resource.quorum].join(" ")
  else
    monitor_string = [new_resource.monitor_address, new_resource.monitor_port, new_resource.quorum].join(" ")
  end

  Chef::Log.info(monitor_string)
  new_resource.monitor     new_resource.monitor   || monitor_string
end

action :create do
  create_user_and_group
  create_directories
  create_service_script
  create_config
  enable_service
  new_resource.updated_by_last_action(true)
end

action :destroy do
  new_resource.updated_by_last_action(true)
end

def create_user_and_group
  group new_resource.group

  user new_resource.user do
    gid new_resource.group
  end
end

def create_directories
  directory "#{::File.dirname(new_resource.log_file)} (#{new_resource.name})" do
    path ::File.dirname(new_resource.log_file)
    owner new_resource.user
    group new_resource.group
    mode 00755
    only_if { new_resource.log_file.downcase != "stdout" }
  end

  directory new_resource.conf_dir do
    owner "root"
    group "root"
    mode 00755
  end

end

def create_service_script
  template "/etc/init.d/redis-sentinel-#{new_resource.name}" do
    source 'redis-sentinel.init.erb'
    mode 0755
    variables new_resource.to_hash
  end
end

def create_config
  template "#{new_resource.conf_dir}/redis-sentinel-#{new_resource.name}.conf" do
    source 'sentinel.conf.erb'
    owner "root"
    group "root"
    mode 00644
    variables :sentinel => new_resource.state,
              :master_name => new_resource.master_name,
              :config => {
                :port      => new_resource.port,
                :pidfile   => new_resource.pidfile,
                :logfile   => new_resource.log_file,
                :daemonize => new_resource.daemonize,
              }
    case new_resource.init_style
    when "init"
      notifies :restart, "service[redis-sentinel-#{new_resource.name}]"
    when "runit"
      notifies :restart, "runit_service[redis-sentinel-#{new_resource.name}]"
    end
  end
end

def enable_service
  service "redis-sentinel-#{new_resource.name}" do
    action [:enable, :start]
  end
end

def get_cluster_master
  return if node.redis.redis_cluster_name.empty?

  #Search for all redis nodes on cluster
  redis_hosts = search(
    :node,
    "redis_cluster_name:#{node.redis.redis_cluster_name} AND \
    recipes:redis\\:\\:server AND \
    chef_environment:#{node.chef_environment}"
  )

  #Remove self from list
  redis_hosts.reject!{|n| n.fqdn == node.fqdn}

  if redis_hosts.any?
    #Try to connect to first redis
    #TODO IMPLEMENT RESCUE AND TRY IF TIMEOUT
    redis_host_connection = "#{::File.join(node.redis.dst_dir, 'bin/redis-cli')} \
        -h #{redis_hosts.first.fqdn} \
        -p #{redis_hosts.first.redis.config.port}"

    redis_role = %x{ #{redis_host_connection} info | grep ^role }.chomp!
    if redis_role.kind_of?(String)
      if redis_role.end_with?("master")
        # First is the master
        master_host = redis_hosts.first.fqdn
        master_port = redis_hosts.first.redis.config.port
      else
        # Get master info
        master_host = %x[
          #{redis_host_connection} info | grep ^master_host
        ].chomp.split(/master_host:/).pop

        master_port = %x[
          #{redis_host_connection} info | grep ^master_port
        ].chomp.split(/master_port:/).pop
      end
    end
  end

  if master_host
    # Slave
    return "#{master_host} #{master_port.to_s}"
  else
    # Master
    return
  end
end
