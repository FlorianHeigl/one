require 'openssl'

module VCenterDriver

class VIClient
    attr_accessor :vim
    attr_accessor :rp

    def initialize(opts)
        opts = {:insecure => true}.merge(opts)
        @vim = RbVmomi::VIM.connect(opts)

        rp_ref = opts.delete(:rp)
        @rp = RbVmomi::VIM::ResourcePool(@vim, rp_ref) if rp_ref
    end

    def rp_confined?
        !!@rp
    end

    # @return RbVmomi::VIM::<type> objects
    def self.get_entities(folder, type, entities=[])
        if folder == []
            return nil
        end

        folder.childEntity.each do |child|
            the_name, junk = child.to_s.split('(')
            case the_name
            when "Folder"
                get_entities(child, type, entities)
            when type
                entities.push(child)
            end
        end

        return entities
    end

    def self.new_from_host(host_id)
        client = OpenNebula::Client.new
        host = OpenNebula::Host.new_with_id(host_id, client)
        rc = host.info
        if OpenNebula.is_error?(rc)
            puts rc.message
            exit -1
        end

        password = host["TEMPLATE/VCENTER_PASSWORD"]

        system = OpenNebula::System.new(client)
        config = system.get_configuration
        if OpenNebula.is_error?(config)
            puts "Error getting oned configuration : #{config.message}"
            exit -1
        end

        token = config["ONE_KEY"]

        password = VIClient::decrypt(password, token)

        connection = {
            :host     => host["TEMPLATE/VCENTER_HOST"],
            :user     => host["TEMPLATE/VCENTER_USER"],
            :rp       => host["TEMPLATE/VCENTER_RESOURCE_POOL"],
            :password => password
        }

        self.new(connection)
    end

    def self.new_from_hostname(hostname)
        client = OpenNebula::Client.new
        host_pool = OpenNebula::HostPool.new(client)
        rc = host_pool.info
        if OpenNebula.is_error?(rc)
            puts "Error getting oned configuration : #{rc.message}"
            exit -1
        end

        host_id = host_pool.select do |host_element|
            host_element.name == hostname
        end.first.id rescue nil

        if host_id
            new_from_host(host_id)
        else
            puts "Could not find host_id for host: #{hostname}"
            exit -1
        end
    end

    def self.decrypt(msg, token)
        begin
            cipher = OpenSSL::Cipher.new("aes-256-cbc")

            cipher.decrypt

            # Truncate for Ruby 2.4 (in previous versions this was being
            #  automatically truncated)
            cipher.key = token[0..31]

            msg =  cipher.update(Base64::decode64(msg))
            msg << cipher.final
        rescue
            puts "Error decrypting secret."
            exit -1
        end
    end
end

end # module VCenterDriver