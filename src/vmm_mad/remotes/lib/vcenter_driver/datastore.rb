module VCenterDriver

class DatastoreFolder
    attr_accessor :item, :items

    def initialize(item)
        @item = item
        @items = {}
    end

    ########################################################################
    # Builds a hash with Datastore-Ref / Datastore to be used as a cache
    # @return [Hash] in the form
    #   { ds_ref [Symbol] => Datastore object }
    ########################################################################
    def fetch!
        VIClient.get_entities(@item, "Datastore").each do |item|
            item_name = item._ref
            @items[item_name.to_sym] = Datastore.new(item)
        end

        VIClient.get_entities(@item, "StoragePod").each do |sp|
            @items[sp._ref.to_sym] = StoragePod.new(sp)
            VIClient.get_entities(sp, "Datastore").each do |item|
                item_name = item._ref
                @items[item_name.to_sym] = Datastore.new(item)
            end
        end
    end

    def monitor
        monitor = ""
        @items.values.each do |ds|
            monitor << "VCENTER_DS_REF=\"#{ds['_ref']}\"\n"
        end
        monitor
    end

    ########################################################################
    # Returns a Datastore or StoragePod. Uses the cache if available.
    # @param ref [Symbol] the vcenter ref
    # @return Datastore
    ########################################################################
    def get(ref)
        if !@items[ref.to_sym]
            if ref.start_with?("group-")
                rbvmomi_spod = RbVmomi::VIM::StoragePod.new(@item._connection, ref) rescue nil
                @items[ref.to_sym] = StoragePod.new(rbvmomi_spod)
            else
                rbvmomi_ds = RbVmomi::VIM::Datastore.new(@item._connection, ref) rescue nil
                @items[ref.to_sym] = Datastore.new(rbvmomi_ds)
            end
        end
        @items[ref.to_sym]
    end
end # class DatastoreFolder

class Storage
    attr_accessor :item

    include Memoize

    def self.new_from_ref(ref, vi_client)
        if ref.start_with?('group-')
            return VCenterDriver::StoragePod.new_from_ref(ref, vi_client)
        else
            return VCenterDriver::Datastore.new_from_ref(ref, vi_client)
        end
    end

    def self.get_image_import_template(ds_name, image_path, image_type, ipool)
        one_image = ""

        # Remove ds info from path
        image_path.sub!(/^\[#{ds_name}\] /, "")

        # Get image name
        file_name = File.basename(image_path).gsub(/\.vmdk$/,"")
        image_name = "#{file_name} - #{ds_name}"

        #Chek if the image has already been imported
        if VCenterDriver::VIHelper.find_by_name(OpenNebula::ImagePool,
                                                image_name,
                                                ipool,
                                                false).nil?
            #Set template
            one_image << "NAME=\"#{image_name}\"\n"
            one_image << "PATH=\"vcenter://#{image_path}\"\n"
            one_image << "TYPE=\"#{image_type}\"\n"
            one_image << "PERSISTENT=\"NO\"\n"
            one_image << "OPENNEBULA_MANAGED=\"YES\"\n"
        end

        return one_image
    end

    def self.get_one_image_ds_by_ref_and_ccr(ref, ccr_ref, vcenter_uuid, pool = nil)
        pool = VCenterDriver::VIHelper.one_pool(OpenNebula::DatastorePool, false) if pool.nil?
        element = pool.select do |e|
            e["TEMPLATE/TYPE"]                == "IMAGE_DS" &&
            e["TEMPLATE/VCENTER_DS_REF"]      == ref &&
            e["TEMPLATE/VCENTER_CCR_REF"]     == ccr_ref &&
            e["TEMPLATE/VCENTER_INSTANCE_ID"] == vcenter_uuid
        end.first rescue nil

        return element
    end


    def monitor
        summary = self['summary']

        total_mb = (summary.capacity.to_i / 1024) / 1024
        free_mb  = (summary.freeSpace.to_i / 1024) / 1024
        used_mb  = total_mb - free_mb

        "USED_MB=#{used_mb}\nFREE_MB=#{free_mb} \nTOTAL_MB=#{total_mb}"
    end

    def self.exists_one_by_ref_ccr_and_type?(ref, ccr_ref, vcenter_uuid, type, pool = nil)
        pool = VCenterDriver::VIHelper.one_pool(OpenNebula::DatastorePool, false) if pool.nil?
        elements = pool.select do |e|
            e["TEMPLATE/TYPE"] == type &&
            e["TEMPLATE/VCENTER_DS_REF"] == ref &&
            e["TEMPLATE/VCENTER_CCR_REF"] == ccr_ref &&
            e["TEMPLATE/VCENTER_INSTANCE_ID"] == vcenter_uuid
        end

        return elements.size == 1
    end

    def to_one(ds_name, vcenter_uuid, ccr_ref, host_id)
        one = ""
        one << "NAME=\"#{ds_name}\"\n"
        one << "TM_MAD=vcenter\n"
        one << "VCENTER_INSTANCE_ID=\"#{vcenter_uuid}\"\n"
        one << "VCENTER_CCR_REF=\"#{ccr_ref}\"\n"
        one << "VCENTER_DS_REF=\"#{self['_ref']}\"\n"
        one << "VCENTER_ONE_HOST_ID=\"#{host_id}\"\n"

        return one
    end

    def to_one_template(one_clusters, ccr_ref, ccr_name, type, vcenter_uuid)

        one_cluster = one_clusters.select { |ccr| ccr[:ref] == ccr_ref }.first rescue nil

        return nil if one_cluster.nil?

        ds_name = ""

        if type == "IMAGE_DS"
            ds_name = "#{self['name']} - #{ccr_name} (IMG)"
        else
            ds_name = "#{self['name']} - #{ccr_name} (SYS)"
        end

        one_tmp = {
            :name     => ds_name,
            :total_mb => ((self['summary.capacity'].to_i / 1024) / 1024),
            :free_mb  => ((self['summary.freeSpace'].to_i / 1024) / 1024),
            :cluster  => ccr_name,
            :one  => to_one(ds_name, vcenter_uuid, ccr_ref, one_cluster[:host_id])
        }

        if type == "SYSTEM_DS"
            one_tmp[:one] << "TYPE=SYSTEM_DS\n"
        else
            one_tmp[:one] << "DS_MAD=vcenter\n"
            one_tmp[:one] << "TYPE=IMAGE_DS\n"
        end

        return one_tmp
    end


end # class Storage

class StoragePod < Storage

    def initialize(item, vi_client=nil)
        if !item.instance_of? RbVmomi::VIM::StoragePod
            raise "Expecting type 'RbVmomi::VIM::StoragePod'. " <<
                  "Got '#{item.class} instead."
        end

        @item = item
    end

     # This is never cached
    def self.new_from_ref(ref, vi_client)
        self.new(RbVmomi::VIM::StoragePod.new(vi_client.vim, ref), vi_client)
    end
end # class StoragePod

class Datastore < Storage

    attr_accessor :one_item

    def initialize(item, vi_client=nil)
        if !item.instance_of? RbVmomi::VIM::Datastore
            raise "Expecting type 'RbVmomi::VIM::Datastore'. " <<
                  "Got '#{item.class} instead."
        end

        @item = item
        @one_item = {}
    end

    def create_virtual_disk(img_name, size, adapter_type, disk_type)
        leading_dirs = img_name.split('/')[0..-2]
        if !leading_dirs.empty?
            create_directory(leading_dirs.join('/'))
        end

        ds_name = self['name']

        vmdk_spec = RbVmomi::VIM::FileBackedVirtualDiskSpec(
            :adapterType => adapter_type,
            :capacityKb  => size.to_i*1024,
            :diskType    => disk_type
        )

        get_vdm.CreateVirtualDisk_Task(
          :datacenter => get_dc.item,
          :name       => "[#{ds_name}] #{img_name}.vmdk",
          :spec       => vmdk_spec
        ).wait_for_completion

        "#{img_name}.vmdk"
    end

    def delete_virtual_disk(img_name)
        ds_name = self['name']

        get_vdm.DeleteVirtualDisk_Task(
          :name => "[#{ds_name}] #{img_name}",
          :datacenter => get_dc.item
        ).wait_for_completion
    end

    # Copy a VirtualDisk
    # @param ds_name [String] name of the datastore
    # @param img_str [String] path to the VirtualDisk
    def copy_virtual_disk(src_path, target_ds_name, target_path)
        leading_dirs = target_path.split('/')[0..-2]
        if !leading_dirs.empty?
            create_directory(leading_dirs.join('/'))
        end

        source_ds_name = self['name']

        copy_params = {
            :sourceName       => "[#{source_ds_name}] #{src_path}",
            :sourceDatacenter => get_dc.item,
            :destName         => "[#{target_ds_name}] #{target_path}"
        }

        get_vdm.CopyVirtualDisk_Task(copy_params).wait_for_completion

        target_path
    end

    def create_directory(directory)
        ds_name = self['name']

        create_directory_params = {
            :name                     => "[#{ds_name}] #{directory}",
            :datacenter               => get_dc.item,
            :createParentDirectories  => true
        }

        begin
            get_fm.MakeDirectory(create_directory_params)
        rescue RbVmomi::VIM::FileAlreadyExists => e
            # Do nothing if directory already exists
        end
    end

    def rm_directory(directory)
        ds_name = self['name']

        rm_directory_params = {
            :name                     => "[#{ds_name}] #{directory}",
            :datacenter               => get_dc.item
        }

        get_fm.DeleteDatastoreFile_Task(rm_directory_params)
    end

    def dir_empty?(path)
        ds_name = self['name']

        spec = RbVmomi::VIM::HostDatastoreBrowserSearchSpec.new

        search_params = {
            'datastorePath' => "[#{ds_name}] #{path}",
            'searchSpec'    => spec
        }

        ls = self['browser'].SearchDatastoreSubFolders_Task(search_params)

        ls.info.result && ls.info.result.length == 1  && \
                ls.info.result.first.file.length == 0
    end

    def upload_file(source_path, target_path)
        @item.upload(target_path, source_path)
    end

    def download_file(source, target)
        @item.download(url_prefix + file, temp_folder + file)
    end

    # Get file size for image handling
    def stat(img_str)
        ds_name = self['name']
        img_path = File.dirname img_str
        img_name = File.basename img_str

        # Create Search Spec
        search_params = get_search_params(ds_name, img_path, img_name)

        # Perform search task and return results
        begin
            search_task = self['browser'].
                SearchDatastoreSubFolders_Task(search_params)

            search_task.wait_for_completion

            file_size = search_task.info.result[0].file[0].fileSize rescue nil

            raise "Could not get file size" if file_size.nil?

            (file_size / 1024) / 1024

        rescue
            raise "Could not find file."
        end
    end

    def get_search_params(ds_name, img_path=nil, img_name=nil)
        spec         = RbVmomi::VIM::HostDatastoreBrowserSearchSpec.new
        spec.query   = [RbVmomi::VIM::VmDiskFileQuery.new,
                        RbVmomi::VIM::IsoImageFileQuery.new]
        spec.details = RbVmomi::VIM::FileQueryFlags(:fileOwner    => true,
                                                    :fileSize     => true,
                                                    :fileType     => true,
                                                    :modification => true)


        spec.matchPattern = img_name.nil? ? [] : [img_name]

        datastore_path = "[#{ds_name}]"
        datastore_path << " #{img_path}" if !img_path.nil?

        search_params = {'datastorePath' => datastore_path,
                         'searchSpec'    => spec}

        return search_params
    end

    def get_fm
        self['_connection.serviceContent.fileManager']
    end

    def get_vdm
        self['_connection.serviceContent.virtualDiskManager']
    end

    def get_dc
        item = @item

        while !item.instance_of? RbVmomi::VIM::Datacenter
            item = item.parent
            if item.nil?
                raise "Could not find the parent Datacenter"
            end
        end

        Datacenter.new(item)
    end

    def get_dc_path
        dc = get_dc
        p = dc.item.parent
        path = [dc.item.name]
        while p.instance_of? RbVmomi::VIM::Folder
            path.unshift(p.name)
            p = p.parent
        end
        path.delete_at(0) # The first folder is the root "Datacenters"
        path.join('/')
    end

    def generate_file_url(path)
        protocol = self[_connection.http.use_ssl?] ? 'https://' : 'http://'
        hostname = self[_connection.http.address]
        port     = self[_connection.http.port]
        dcpath   = get_dc_path

        # This creates the vcenter file URL for uploading or downloading files
        # e.g:
        url = "#{protocol}#{hostname}:#{port}/folder/#{path}?dcPath=#{dcpath}&dsName=#{self[name]}"
        return url
    end

    def download_to_stdout(remote_path)
        url = generate_file_url(remote_path)
        pid = spawn(CURLBIN,
                    "-k", '--noproxy', '*', '-f',
                    "-b", self[_connection.cookie],
                    url)

        Process.waitpid(pid, 0)
        fail "download failed" unless $?.success?
    end

    def is_descriptor?(remote_path)
        url = generate_file_url(remote_path)

        rout, wout = IO.pipe
        pid = spawn(CURLBIN,
                    "-I", "-k", '--noproxy', '*', '-f',
                    "-b", _connection.cookie,
                    url,
                    :out => wout,
                    :err => '/dev/null')

        Process.waitpid(pid, 0)
        fail "read image header failed" unless $?.success?

        wout.close
        size = rout.readlines.select{|l|
            l.start_with?("Content-Length")
        }[0].sub("Content-Length: ","")
        rout.close
        size.chomp.to_i < 4096   # If <4k, then is a descriptor
    end

    def get_text_file remote_path
        url = generate_file_url(remote_path)

        rout, wout = IO.pipe
        pid = spawn CURLBIN, "-k", '--noproxy', '*', '-f',
                    "-b", _connection.cookie,
                    url,
                    :out => wout,
                    :err => '/dev/null'

        Process.waitpid(pid, 0)
        fail "get text file failed" unless $?.success?

        wout.close
        output = rout.readlines
        rout.close
        return output
    end

    def get_images(vcenter_uuid)
        img_templates = []
        ds_id = nil
        ds_name = self['name']

        img_types = ["FloppyImageFileInfo",
                     "IsoImageFileInfo",
                     "VmDiskFileInfo"]

        ipool = VCenterDriver::VIHelper.one_pool(OpenNebula::ImagePool, false)
        if ipool.respond_to?(:message)
            raise "Could not get OpenNebula ImagePool: #{pool.message}"
        end

        dpool = VCenterDriver::VIHelper.one_pool(OpenNebula::DatastorePool, false)
        if dpool.respond_to?(:message)
            raise "Could not get OpenNebula DatastorePool: #{pool.message}"
        end

        ds_id = @one_item["ID"]

        begin
            # Create Search Spec
            search_params = get_search_params(ds_name)

            # Perform search task and return results
            search_task = self['browser'].
                SearchDatastoreSubFolders_Task(search_params)
            search_task.wait_for_completion

            search_task.info.result.each { |image|
                folderpath = ""
                if image.folderPath[-1] != "]"
                    folderpath = image.folderPath.sub(/^\[#{ds_name}\] /, "")
                end

                image = image.file.first

                # Skip not relevant files
                next if !img_types.include? image.class.to_s

                # Get image path and name
                image_path = folderpath
                image_path << image.path
                image_name = File.basename(image.path).reverse.sub("kdmv.","").reverse

                # Get image and disk type
                image_type = image.class.to_s == "VmDiskFileInfo" ? "OS" : "CDROM"
                disk_type = image.class.to_s == "VmDiskFileInfo" ? image.diskType : nil

                #Set template
                one_image =  "NAME=\"#{image_name} - #{ds_name}\"\n"
                one_image << "PATH=\"vcenter://#{image_path}\"\n"
                one_image << "PERSISTENT=\"YES\"\n"
                one_image << "TYPE=\"#{image_type}\"\n"
                one_image << "VCENTER_DISK_TYPE=\"#{disk_type}\"\n" if disk_type

                if VCenterDriver::VIHelper.find_by_name(OpenNebula::ImagePool,
                                                        "#{image_name} - #{ds_name}",
                                                        ipool,
                                                        false).nil?
                    img_templates << {
                        :name        => "#{image_name} - #{ds_name}",
                        :path        => image_path,
                        :size        => (image.fileSize / 1024).to_s,
                        :type        => image.class.to_s,
                        :dsid        => ds_id,
                        :one         => one_image
                    }
                end
            }

        rescue
            raise "Could not find images."
        end

        return img_templates
    end

    # This is never cached
    def self.new_from_ref(ref, vi_client)
        self.new(RbVmomi::VIM::Datastore.new(vi_client.vim, ref), vi_client)
    end
end # class Datastore

end # module VCenterDriver
