
module OneDBFsck
    # Initialize all the host counters to 0
    def init_host_counters
        @db.fetch("SELECT oid, name FROM host_pool") do |row|
            counters[:host][row[:oid]] = {
                :name   => row[:name],
                :memory => 0,
                :cpu    => 0,
                :rvms   => Set.new
            }
        end
    end

    def check_host_cluster
        cluster = @data_cluster
        hosts_fix = @fixes_host_cluster = {}

        @db.fetch("SELECT oid,body,cid FROM host_pool") do |row|
            doc = Document.new(row[:body])

            cluster_id = doc.root.get_text('CLUSTER_ID').to_s.to_i
            cluster_name = doc.root.get_text('CLUSTER')

            if cluster_id != row[:cid]
                log_error("Host #{row[:oid]} is in cluster #{cluster_id}, " <<
                          "but cid column has cluster #{row[:cid]}")
                hosts_fix[row[:oid]] = {:body => row[:body], :cid => cluster_id}
            end

            if cluster_id != -1
                cluster_entry = cluster[cluster_id]

                if cluster_entry.nil?
                    log_error("Host #{row[:oid]} is in cluster " <<
                              "#{cluster_id}, but it does not exist")

                    doc.root.each_element('CLUSTER_ID') do |e|
                        e.text = "-1"
                    end

                    doc.root.each_element('CLUSTER') do |e|
                        e.text = ""
                    end

                    hosts_fix[row[:oid]] = {:body => doc.root.to_s, :cid => -1}
                else
                    if cluster_name != cluster_entry[:name]
                        log_error("Host #{row[:oid]} has a wrong name for " <<
                              "cluster #{cluster_id}, #{cluster_name}. " <<
                              "It will be changed to #{cluster_entry[:name]}")

                        doc.root.each_element('CLUSTER') do |e|
                            e.text = cluster_entry[:name]
                        end

                        hosts_fix[row[:oid]] = {
                            body: doc.root.to_s,
                            cid: cluster_id
                        }
                    end

                    cluster_entry[:hosts] << row[:oid]
                end
            end
        end
    end

    def fix_host_cluster
        @db.transaction do
            @fixes_host_cluster.each do |id, entry|
                @db[:host_pool].where(oid: id).update(
                    body: entry[:body],
                    cid: entry[:cid]
                )
            end
        end
    end
end

