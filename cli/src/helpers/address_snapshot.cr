module VoIPAppz
  # Pure reconciliation plan for the provider ACL owned by config/va.yaml.
  # Kamctl removes address rows by group + IP, so a changed row is removed and
  # recreated before Kamailio is reloaded.
  module AddressSnapshot
    extend self

    record Row, grp : Int32, ip : String, mask : Int32, port : Int32, tag : String
    record Plan,
      remove : Array(NamedTuple(grp: Int32, ip: String)),
      add : Array(Row),
      keep : Array(Row)

    def plan(existing : Array(Row), desired : Array(Row), group : Int32) : Plan
      wanted = {} of String => Row
      desired.select { |row| row.grp == group }.each do |row|
        if previous = wanted[row.ip]?
          unless previous == row
            raise ArgumentError.new("multiple provider definitions use #{row.ip} with different mask, port, or tag")
          end
        else
          wanted[row.ip] = row
        end
      end

      current = Hash(String, Array(Row)).new { |hash, ip| hash[ip] = [] of Row }
      existing.select { |row| row.grp == group }.each { |row| current[row.ip] << row }

      remove = [] of NamedTuple(grp: Int32, ip: String)
      add = [] of Row
      keep = [] of Row

      (current.keys | wanted.keys).sort.each do |ip|
        rows = current[ip]? || [] of Row
        row = wanted[ip]?

        if row && rows.size == 1 && rows.first == row
          keep << row
          next
        end

        remove << {grp: group, ip: ip} unless rows.empty?
        add << row if row
      end

      Plan.new(remove, add, keep)
    end
  end
end
