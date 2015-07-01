module ForemanXen
  class Xenserver < ComputeResource
    validates_presence_of :url, :user, :password

    def provided_attributes
      super.merge(
        { :uuid => :reference,
          :mac  => :mac
        })
    end

    def capabilities
      [:build]
    end

    def find_vm_by_uuid(ref)
      client.servers.get(ref)
    rescue Fog::XenServer::RequestFailed => e
      raise(ActiveRecord::RecordNotFound) if e.message.include?('HANDLE_INVALID')
      raise(ActiveRecord::RecordNotFound) if e.message.include?('VM.get_record: ["SESSION_INVALID"')
      raise e
    end

    # we default to destroy the VM's storage as well.
    def destroy_vm(ref, args = {})
      find_vm_by_uuid(ref).destroy
    rescue ActiveRecord::RecordNotFound
      true
    end

    def self.model_name
      ComputeResource.model_name
    end

    def max_cpu_count
      ## 16 is a max number of cpus per vm according to XenServer doc
      [hypervisor.host_cpus.size, 16].min
    end

    def max_memory
      xenServerMaxDoc = 128*1024*1024*1024
      [hypervisor.metrics.memory_total.to_i, xenServerMaxDoc].min
    rescue => e
      logger.debug "unable to figure out free memory, guessing instead due to:#{e}"
      16*1024*1024*1024
    end

    def test_connection(options = {})
      super
      errors[:url].empty? and hypervisor
    rescue => e
      disconnect rescue nil
      errors[:base] << e.message
    end

    def new_nic(attr={})
      client.networks.new attr
    end

    def new_volume(attr={})
      client.storage_repositories.new attr
    end

    def storage_pools
        results = Array.new
	
        storages = client.storage_repositories.select { |sr| sr.type!= 'udev' && sr.type!= 'iso'} rescue []
	hosts = client.hosts

	storages.each do |sr|
		subresults = Hash.new()
		found = 0
		hosts.each do |host|

			if (sr.reference == host.suspend_image_sr) 
				found = 1
				subresults[:name] 		= sr.name
				subresults[:display_name]	= sr.name + '(' +  host.hostname + ')'
				subresults[:uuid]		= sr.uuid
				break
			end

		end
		
		if (found==0) 
			subresults[:name] 		= sr.name
			subresults[:display_name] 	= sr.name
			subresults[:uuid]		= sr.uuid
		end
		results.push(subresults)
	end

	results.sort_by!{|item| item[:display_name] }
	return results

    end

    def interfaces
      client.interfaces rescue []
    end

    def networks
      networks = client.networks rescue []
      networks.sort { |a, b| a.name <=> b.name }
    end

    def templates
      client.servers.templates rescue []
    end

    def custom_templates
      tmps = client.servers.custom_templates.select { |t| !t.is_a_snapshot } rescue []
      tmps.sort { |a, b| a.name <=> b.name }
    end

    def builtin_templates
      tmps = client.servers.builtin_templates.select { |t| !t.is_a_snapshot } rescue []
      tmps.sort { |a, b| a.name <=> b.name }
    end

    def associated_host(vm)
      associate_by("mac", vm.interfaces.map(&:mac))
    end

    def get_snapshots_for_vm(vm)
      if vm.snapshots.empty?
        return []
      end
      tmps = client.servers.templates.select { |t| t.is_a_snapshot } rescue []
      retval = []
      tmps.each do | snapshot |
        retval << snapshot if vm.snapshots.include?(snapshot.reference)
      end
      retval
    end

    def get_snapshots
      tmps = client.servers.templates.select { |t| t.is_a_snapshot } rescue []
      tmps.sort { |a, b| a.name <=> b.name }
    end

    def new_vm(attr={})

      test_connection
      return unless errors.empty?
      opts = vm_instance_defaults.merge(attr.to_hash).symbolize_keys

      [:networks, :volumes].each do |collection|
        nested_attrs     = opts.delete("#{collection}_attributes".to_sym)
        opts[collection] = nested_attributes_for(collection, nested_attrs) if nested_attrs
      end
      opts.reject! { |_, v| v.nil? }
      client.servers.new opts
    end

    def create_vm(args = {})
      custom_template_name  = args[:custom_template_name]
      builtin_template_name = args[:builtin_template_name]
      raise 'you can select at most one template type' if builtin_template_name != '' and custom_template_name != ''
      begin
        vm = nil
        if custom_template_name != ''
          vm = create_vm_from_custom args
        else
          vm = create_vm_from_builtin args
        end
        vm.set_attribute('name_description', 'Provisioned by Foreman')
        cpus = args[:vcpus_max]
        if vm.vcpus_max.to_i < cpus.to_i
          vm.set_attribute('VCPUs_max', cpus)
          vm.set_attribute('VCPUs_at_startup', cpus)
        else
          vm.set_attribute('VCPUs_at_startup', cpus)
          vm.set_attribute('VCPUs_max', cpus)
        end
        vm.refresh
        return vm
      rescue => e
        logger.info e
        logger.info e.backtrace.join("\n")
        return false
      end
    end

    def create_vm_from_custom(args)
      mem_max = args[:memory_max]
      mem_min = args[:memory_min]

      raise 'Memory max cannot be lower than Memory min' if mem_min.to_i > mem_max.to_i
      vm = client.servers.new :name          => args[:name],
                              :template_name => args[:custom_template_name]

      vm.save :auto_start => false

      vm.provision

      vm.vifs.first.destroy rescue nil

      create_network(vm, args)

      args['xenstore']['vm-data']['ifs']['0']['mac'] = vm.vifs.first.mac
      xenstore_data                                  = xenstore_hash_flatten(args['xenstore'])

      vm.set_attribute('xenstore_data', xenstore_data)
      if vm.memory_static_max.to_i < mem_max.to_i
        vm.set_attribute('memory_static_max', mem_max)
        vm.set_attribute('memory_dynamic_max', mem_max)
        vm.set_attribute('memory_dynamic_min', mem_min)
        vm.set_attribute('memory_static_min', mem_min)
      else
        vm.set_attribute('memory_static_min', mem_min)
        vm.set_attribute('memory_dynamic_min', mem_min)
        vm.set_attribute('memory_dynamic_max', mem_max)
        vm.set_attribute('memory_static_max', mem_max)
      end

      disks = vm.vbds.select { |vbd| vbd.type == 'Disk' }
      disks.sort! { |a, b| a.userdevice <=> b.userdevice }
      i = 0
      disks.each do |vbd|
        vbd.vdi.set_attribute('name-label', "#{args[:name]}_#{i}")
        i+=1
      end
      vm
    end

    def create_vm_from_builtin(args)

      host               = client.hosts.first
      storage_repository = client.storage_repositories.find { |sr| sr.uuid == "#{args[:VBDs][:sr_uuid]}" }

      gb   = 1073741824 #1gb in bytes
      size = args[:VBDs][:physical_size].to_i * gb
      vdi  = client.vdis.create :name               => "#{args[:name]}-disk1",
                                :storage_repository => storage_repository,
                                :description        => "#{args[:name]}-disk_1",
                                :virtual_size       => size.to_s

      mem_max      = args[:memory_max]
      mem_min      = args[:memory_min]
      other_config = {}
      if args[:builtin_template_name] != ''
        template     = client.servers.builtin_templates.find { |tmp| tmp.name == args[:builtin_template_name] }
        other_config = template.other_config
        other_config.delete 'disks'
        other_config.delete 'default_template'
        other_config['mac_seed'] = SecureRandom.uuid
      end
      vm = client.servers.new :name               => args[:name],
                              :affinity           => host,
                              :pv_bootloader      => '',
                              :hvm_boot_params    => { :order => 'nc' },
                              :other_config       => other_config,
                              :memory_static_max  => mem_max,
                              :memory_static_min  => mem_min,
                              :memory_dynamic_max => mem_max,
                              :memory_dynamic_min => mem_min

      vm.save :auto_start => false
      client.vbds.create :server => vm, :vdi => vdi

      create_network(vm, args)

      vm.provision
      vm.set_attribute('HVM_boot_policy', 'BIOS order')
      vm.refresh
      vm
    end

    def console uuid
      vm = find_vm_by_uuid(uuid)
      raise 'VM is not running!' unless vm.ready?

      console = vm.service.consoles.find { |c| c.__vm == vm.reference && c.protocol == 'rfb' }
      raise "No console fore vm #{vm.name}" if console == nil

      session_ref = (vm.service.instance_variable_get :@connection).instance_variable_get :@credentials
      fullURL     = "#{console.location}&session_id=#{session_ref}"
      tunnel      = VNCTunnel.new fullURL
      tunnel.start
      logger.info 'VNCTunnel started'
      WsProxy.start(:host => tunnel.host, :host_port => tunnel.port, :password => '').merge(:type => 'vnc', :name => vm.name)

    rescue Error => e
      logger.warn e
      raise e
    end

    def hypervisor
      client.hosts.first
    end

    protected

    def client
      @client ||= ::Fog::Compute.new({ :provider => 'XenServer', :xenserver_url => url, :xenserver_username => user, :xenserver_password => password })
    end

    def disconnect
      client.terminate if @client
      @client = nil
    end

    def vm_instance_defaults
      super.merge({})
    end


    private

    def create_network(vm, args)
      net        = client.networks.find { |n| n.name == args[:VIFs][:print] }
      net_config = {
        'MAC_autogenerated'    => 'True',
        'VM'                   => vm.reference,
        'network'              => net.reference,
        'MAC'                  => '',
        'device'               => '0',
        'MTU'                  => '0',
        'other_config'         => {},
        'qos_algorithm_type'   => 'ratelimit',
        'qos_algorithm_params' => {}
      }
      client.create_vif_custom net_config
      vm.reload
    end

    def xenstore_hash_flatten(nested_hash, key=nil, keychain=nil, out_hash={})
      nested_hash.each do |k, v|
        if v.is_a? Hash
          xenstore_hash_flatten(v, k, "#{keychain}#{k}/", out_hash)
        else
          out_hash["#{keychain}#{k}"] = v
        end
      end
      out_hash
#      @key = key
    end
  end
end
