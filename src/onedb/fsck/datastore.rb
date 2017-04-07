
module OneDBFsck

    def init_datastore_counters
    end

    def check_datastore_cluster
        cluster = @data_cluster
        @fixes_datastore_cluster = {}

        @db.fetch("SELECT oid,body FROM datastore_pool") do |row|
            doc = nokogiri_doc(row[:body])

            doc.root.xpath("CLUSTERS/ID").each do |e|
                cluster_id = e.text.to_i

                cluster_entry = cluster[cluster_id]

                if cluster_entry.nil?
                    log_error("Datastore #{row[:oid]} is in cluster " <<
                              "#{cluster_id}, but it does not exist")

                    e.remove

                    @fixes_datastore_cluster[row[:oid]] = { body: doc.root.to_s }
                else
                    cluster_entry[:datastores] << row[:oid]
                end
            end
        end
    end

    def fix_datastore_cluster
        @db.transaction do
            @fixes_datastore_cluster.each do |id, entry|
                @db[:datastore_pool].where(oid: id).update(body: entry[:body])
            end
        end
    end
end

