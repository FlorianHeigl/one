
module OneDBFsck

    # Init vnet counters
    def init_network_counters
        @db.fetch("SELECT oid,body FROM network_pool") do |row|
            doc = nokogiri_doc(row[:body])

            ar_leases = {}

            doc.root.xpath("AR_POOL/AR/AR_ID").each do |ar_id|
                ar_leases[ar_id.text.to_i] = {}
            end

            counters[:vnet][row[:oid]] = {
                :ar_leases      => ar_leases,
                :no_ar_leases   => {}
            }
        end
    end

    def check_network_cluster
        cluster = @data_cluster
        @fixes_host_cluster = {}

        @db.fetch("SELECT oid,body FROM network_pool") do |row|
            doc = nokogiri_doc(row[:body])

            doc.root.xpath("CLUSTERS/ID").each do |e|
                cluster_id = e.text.to_i

                cluster_entry = cluster[cluster_id]

                if cluster_entry.nil?
                    log_error("VNet #{row[:oid]} is in cluster " <<
                              "#{cluster_id}, but it does not exist")

                    e.remove

                    @fixes_host_cluster[row[:oid]] = { body: doc.root.to_s }
                else
                    cluster_entry[:vnets] << row[:oid]
                end
            end
        end
    end

    def fix_network_cluster
        @db.transaction do
            @fixes_host_cluster.each do |id, entry|
                @db[:host_pool].where(oid: id).update(body: entry[:body])
            end
        end
    end
end

